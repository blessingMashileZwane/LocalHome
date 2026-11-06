"""Small local ONVIF PTZ client for the HiMost/V380 target.

The camera advertises PTZ on its private ONVIF endpoint (TCP 8899). Requests are
plain SOAP over HTTP on the local network; no vendor cloud is used.
"""

from __future__ import annotations

import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

from v380_lan import is_private_ipv4

NS_S = "http://www.w3.org/2003/05/soap-envelope"
NS_TDS = "http://www.onvif.org/ver10/device/wsdl"
NS_TRT = "http://www.onvif.org/ver10/media/wsdl"
NS_TPTZ = "http://www.onvif.org/ver20/ptz/wsdl"
NS_TT = "http://www.onvif.org/ver10/schema"

MAX_RESPONSE_BYTES = 32 * 1024
MAX_VELOCITY = 0.15
DIRECTIONS = {
    "up": (0.0, 0.15),
    "down": (0.0, -0.15),
    "left": (-0.15, 0.0),
    "right": (0.15, 0.0),
}


class OnvifError(Exception):
    """A local ONVIF validation or transport error."""


class OnvifPtz:
    def __init__(self, ip: str, port: int = 8899, timeout: float = 4.0):
        if not is_private_ipv4(ip):
            raise OnvifError("camera address must be a private IPv4 address")
        self.ip = ip
        self.port = port
        self.timeout = timeout
        self._ptz_url: str | None = None
        self._profile_token: str | None = None

    def initialize(self) -> None:
        if self._ptz_url and self._profile_token:
            return
        device_url = f"http://{self.ip}:{self.port}/onvif/device_service"
        capabilities = self._post(
            device_url,
            "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>",
        )
        ptz_url = _service_address(capabilities, "PTZ")
        media_url = _service_address(capabilities, "Media")
        self._check_local_url(ptz_url)
        self._check_local_url(media_url)
        profiles = self._post(media_url, "<trt:GetProfiles/>")
        self._profile_token = _profile_token(profiles)
        self._ptz_url = ptz_url

    def start(self, direction: str) -> None:
        pan, tilt = _direction(direction)
        self.initialize()
        token = escape(self._profile_token or "")
        self._post(
            self._ptz_url or "",
            f"""<tptz:ContinuousMove>
              <tptz:ProfileToken>{token}</tptz:ProfileToken>
              <tptz:Velocity>
                <tt:PanTilt x="{pan:.2f}" y="{tilt:.2f}"/>
              </tptz:Velocity>
              <tptz:Timeout>PT0.8S</tptz:Timeout>
            </tptz:ContinuousMove>""",
        )

    def stop(self) -> None:
        self.initialize()
        token = escape(self._profile_token or "")
        self._post(
            self._ptz_url or "",
            f"""<tptz:Stop>
              <tptz:ProfileToken>{token}</tptz:ProfileToken>
              <tptz:PanTilt>true</tptz:PanTilt>
              <tptz:Zoom>false</tptz:Zoom>
            </tptz:Stop>""",
        )

    def nudge(self, direction: str, duration: float = 0.4) -> None:
        self.start(direction)
        time.sleep(max(0.15, min(duration, 2.0)))
        self.stop()

    def _check_local_url(self, url: str) -> None:
        parsed = urllib.parse.urlparse(url)
        if (
            parsed.scheme != "http"
            or parsed.hostname != self.ip
            or parsed.port != self.port
            or parsed.username
            or parsed.password
            or not parsed.path
            or parsed.query
            or parsed.fragment
        ):
            raise OnvifError("camera advertised an unsupported ONVIF endpoint")

    def _post(self, url: str, operation: str) -> ET.Element:
        body = f"""<?xml version="1.0" encoding="UTF-8"?>
          <s:Envelope xmlns:s="{NS_S}"
            xmlns:tds="{NS_TDS}"
            xmlns:trt="{NS_TRT}"
            xmlns:tptz="{NS_TPTZ}"
            xmlns:tt="{NS_TT}">
            <s:Body>{operation}</s:Body>
          </s:Envelope>"""
        request = urllib.request.Request(
            url,
            data=body.encode("utf-8"),
            headers={"Content-Type": "application/soap+xml; charset=utf-8"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as error:
            raise OnvifError(f"camera rejected the ONVIF request ({error.code})") from error
        except urllib.error.URLError as error:
            raise OnvifError("could not reach the camera ONVIF service") from error
        if len(payload) > MAX_RESPONSE_BYTES:
            raise OnvifError("camera ONVIF response is too large")
        try:
            root = ET.fromstring(payload)
        except ET.ParseError as error:
            raise OnvifError("camera returned invalid ONVIF XML") from error
        if any(element.tag.rsplit("}", 1)[-1] == "Fault" for element in root.iter()):
            raise OnvifError("camera rejected the ONVIF request")
        return root


def _service_address(root: ET.Element, service: str) -> str:
    for element in root.iter():
        if element.tag == f"{{{NS_TT}}}{service}":
            for child in element:
                if child.tag == f"{{{NS_TT}}}XAddr" and child.text:
                    return child.text.strip()
    raise OnvifError(f"camera did not advertise its {service} service")


def _profile_token(root: ET.Element) -> str:
    for profile in root.iter(f"{{{NS_TRT}}}Profiles"):
        token = profile.get("token")
        if token and profile.find(f"{{{NS_TT}}}PTZConfiguration") is not None:
            return token
    raise OnvifError("camera did not return a usable PTZ profile")


def _direction(value: str) -> tuple[float, float]:
    if value not in DIRECTIONS:
        raise OnvifError("direction must be up, down, left, or right")
    return DIRECTIONS[value]

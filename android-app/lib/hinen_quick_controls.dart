import 'package:flutter/services.dart';

/// Native bridge for the PS300 notification card and Quick Settings tile.
class HinenQuickControls {
  const HinenQuickControls._();

  static const _channel = MethodChannel('localhome/hinen_ui');

  static Future<bool> enableCard() async {
    try {
      return await _channel.invokeMethod<bool>('enableCard') ?? false;
    } on Object {
      return false;
    }
  }

  static Future<bool> disableCard() async {
    try {
      return await _channel.invokeMethod<bool>('disableCard') ?? false;
    } on Object {
      return false;
    }
  }

  static Future<bool> addTile() async {
    try {
      return await _channel.invokeMethod<bool>('addTile') ?? false;
    } on Object {
      return false;
    }
  }
}

#pragma once

#include <string>
#include <flutter/encodable_value.h>
#include <iostream>

struct WindowConfiguration {
  std::string arguments;
  bool hidden_at_launch = false;

  // Kelivo fork extensions (Windows only).
  double width = 0.0;            // 0 = plugin default (800)
  double height = 0.0;           // 0 = plugin default (600)
  std::string title;             // empty = no title
  bool borderless = false;       // strip caption + resize frame
  bool always_on_top = false;    // HWND_TOPMOST
  bool skip_taskbar = false;     // WS_EX_TOOLWINDOW
  bool align_bottom_right = false;  // bottom-right of monitor work area

  static WindowConfiguration FromEncodableMap(
      const flutter::EncodableMap* map) {
    WindowConfiguration config;

    if (!map) return config;

    try {
      auto it = map->find(flutter::EncodableValue("arguments"));
      if (it != map->end()) {
        config.arguments = std::get<std::string>(it->second);
      }

      it = map->find(flutter::EncodableValue("hiddenAtLaunch"));
      if (it != map->end()) {
        config.hidden_at_launch = std::get<bool>(it->second);
      }

      it = map->find(flutter::EncodableValue("width"));
      if (it != map->end()) {
        config.width = std::get<double>(it->second);
      }

      it = map->find(flutter::EncodableValue("height"));
      if (it != map->end()) {
        config.height = std::get<double>(it->second);
      }

      it = map->find(flutter::EncodableValue("title"));
      if (it != map->end()) {
        config.title = std::get<std::string>(it->second);
      }

      it = map->find(flutter::EncodableValue("borderless"));
      if (it != map->end()) {
        config.borderless = std::get<bool>(it->second);
      }

      it = map->find(flutter::EncodableValue("alwaysOnTop"));
      if (it != map->end()) {
        config.always_on_top = std::get<bool>(it->second);
      }

      it = map->find(flutter::EncodableValue("skipTaskbar"));
      if (it != map->end()) {
        config.skip_taskbar = std::get<bool>(it->second);
      }

      it = map->find(flutter::EncodableValue("alignBottomRight"));
      if (it != map->end()) {
        config.align_bottom_right = std::get<bool>(it->second);
      }
    } catch (const std::exception& e) {
      std::cerr << "Failed to parse WindowConfiguration: " << e.what()
                << std::endl;
    }

    return config;
  }
};

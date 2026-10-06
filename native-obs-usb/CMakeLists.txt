锘縞make_minimum_required(VERSION 3.21)
project(applelive_native_output LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "AppleLive native USB components are Windows-only")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS OFF)

set(OBS_SOURCE_DIR "" CACHE PATH "Checked out obs-studio source tree")
set(OBS_BUILD_DIR "" CACHE PATH "Configured obs-studio build tree")
set(OBS_LIBRARY "" CACHE FILEPATH "Import library for the OBS host DLL")
option(APPLELIVE_BUILD_OBS_OUTPUT "Build the OBS output module" ON)

if(APPLELIVE_BUILD_OBS_OUTPUT)
  add_library(applelive-native-output MODULE src/applelive_output.cpp)
  target_include_directories(applelive-native-output PRIVATE include)
  if(EXISTS "${OBS_SOURCE_DIR}/libobs/obs.h")
    target_include_directories(applelive-native-output PRIVATE
      "${OBS_SOURCE_DIR}/libobs"
      "${OBS_SOURCE_DIR}/libobs/util"
      "${OBS_SOURCE_DIR}/deps/media-io")
  endif()
  target_compile_definitions(applelive-native-output PRIVATE _CRT_SECURE_NO_WARNINGS WIN32_LEAN_AND_MEAN NOMINMAX)
  target_link_libraries(applelive-native-output PRIVATE ws2_32)
  if(NOT OBS_LIBRARY AND OBS_BUILD_DIR)
    find_library(OBS_LIBRARY NAMES obs libobs PATHS "${OBS_BUILD_DIR}/libobs" "${OBS_BUILD_DIR}/libobs/Release" NO_DEFAULT_PATH)
  endif()
  if(NOT OBS_LIBRARY)
    message(FATAL_ERROR "OBS_BUILD_DIR must contain libobs/obs.lib (or set OBS_LIBRARY)")
  endif()
  target_link_libraries(applelive-native-output PRIVATE "${OBS_LIBRARY}")
  set_target_properties(applelive-native-output PROPERTIES
    PREFIX ""
    OUTPUT_NAME "applelive-native-output"
    SUFFIX ".dll")
endif()

add_executable(AppleLiveUsbRelay src/applelive_usb_relay.cpp src/plist.cpp)
target_include_directories(AppleLiveUsbRelay PRIVATE include)
target_compile_definitions(AppleLiveUsbRelay PRIVATE _CRT_SECURE_NO_WARNINGS WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(AppleLiveUsbRelay PRIVATE ws2_32)

install(TARGETS AppleLiveUsbRelay RUNTIME DESTINATION .)
if(APPLELIVE_BUILD_OBS_OUTPUT)
  install(TARGETS applelive-native-output RUNTIME DESTINATION obs-plugins/64bit LIBRARY DESTINATION obs-plugins/64bit)
endif()

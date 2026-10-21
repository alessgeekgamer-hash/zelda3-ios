cmake_minimum_required(VERSION 3.22)

# Before project(): they must be in effect while the toolchain is set up.
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
  set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0)
endif()
if(NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES arm64)
endif()

project(zelda3ios C OBJC)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  message(FATAL_ERROR
    "This is the iOS build. Configure with:\n"
    "  cmake -S ios -B build-ios -G Xcode -DCMAKE_SYSTEM_NAME=iOS "
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0")
endif()

set(ZELDA3_IOS_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
set(ZELDA3_DIR ${ZELDA3_IOS_ROOT}/../external/zelda3)
set(SDL_DIR ${ZELDA3_IOS_ROOT}/../external/SDL)
set(ZELDA3_PATCHES_DIR ${ZELDA3_IOS_ROOT}/../patches/zelda3)

if(NOT EXISTS ${SDL_DIR}/CMakeLists.txt OR NOT EXISTS ${ZELDA3_DIR}/src/main.c)
  message(FATAL_ERROR "Git submodules missing. Run: git submodule update --init --recursive")
endif()

# --- SDL2, built static. SDL2main is off: ios_main.c provides main(). ---
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST OFF CACHE BOOL "" FORCE)
set(SDL2_DISABLE_SDL2MAIN ON CACHE BOOL "" FORCE)
add_subdirectory(${SDL_DIR} SDL2 EXCLUDE_FROM_ALL)

# SDL's Objective-C sources use manual reference counting; keep SDL out of
# ARC (our own files opt in below).
set_target_properties(SDL2-static PROPERTIES XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC NO)

# --- zelda3: pristine submodule copied to the build tree, patches applied ---
# Same scheme as the Android build (see app/src/main/cpp/CMakeLists.txt):
# a patch that no longer applies fails the build.
set(ZELDA3_PATCHED ${CMAKE_CURRENT_BINARY_DIR}/zelda3-patched)
file(REMOVE_RECURSE ${ZELDA3_PATCHED})
file(COPY ${ZELDA3_DIR}/src ${ZELDA3_DIR}/snes DESTINATION ${ZELDA3_PATCHED})
# CONFIGURE_DEPENDS: adding a patch file must re-run this configure step.
file(GLOB ZELDA3_PATCHES CONFIGURE_DEPENDS ${ZELDA3_PATCHES_DIR}/*.patch)
list(SORT ZELDA3_PATCHES)
find_package(Git REQUIRED)
foreach(patch ${ZELDA3_PATCHES})
  # Stop git from finding the enclosing repository; inside one, apply would
  # silently skip paths outside the current directory. Upstream files are CRLF
  # in its repository while patches are LF, so line endings are ignored.
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E env GIT_CEILING_DIRECTORIES=${CMAKE_CURRENT_BINARY_DIR}
            ${GIT_EXECUTABLE} apply --verbose --ignore-whitespace ${patch}
    WORKING_DIRECTORY ${ZELDA3_PATCHED}
    RESULT_VARIABLE result
    ERROR_VARIABLE output)
  if(NOT result EQUAL 0 OR NOT output MATCHES "Applied patch")
    message(FATAL_ERROR "Could not apply ${patch}:
${output}")
  endif()
endforeach()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${ZELDA3_PATCHES})

file(GLOB ZELDA3_SOURCES
  ${ZELDA3_PATCHED}/src/*.c
  ${ZELDA3_PATCHED}/snes/*.c
)

add_executable(zelda3 MACOSX_BUNDLE
  src/ios_main.c
  src/MPAppDelegate.m
  src/MPTouchControls.m
  ${ZELDA3_SOURCES}
  ${ZELDA3_DIR}/third_party/gl_core/gl_core_3_1.c
  ${ZELDA3_DIR}/third_party/opus-1.3.1-stripped/opus_decoder_amalgam.c
)

target_include_directories(zelda3 PRIVATE
  ${ZELDA3_PATCHED}
  ${ZELDA3_DIR}
  ${SDL_DIR}/src/video/uikit   # SDL_uikitappdelegate.h, for the delegate subclass
)

target_compile_definitions(zelda3 PRIVATE SYSTEM_VOLUME_MIXER_AVAILABLE=0)
target_compile_options(zelda3 PRIVATE -O2 -Wno-unused-value -Wno-parentheses -Wno-dangling-else)

# SDL links its Apple frameworks PRIVATE, so an app consuming SDL2-static
# from add_subdirectory() has to link them itself.
target_link_libraries(zelda3 PRIVATE
  SDL2::SDL2-static
  UIKit
  Foundation
  CoreGraphics
  QuartzCore
  Metal
  OpenGLES
  GameController
  CoreHaptics
  CoreMotion
  AudioToolbox
  AVFoundation
  CoreAudio
  CoreVideo
  CoreMedia
  Security
)

set_target_properties(zelda3 PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST ${ZELDA3_IOS_ROOT}/Info.plist
  RESOURCE "${ZELDA3_IOS_ROOT}/../app/src/main/assets/zelda3_assets.bps"
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "io.github.alessgeekgamer.zelda3"
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1"
  XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO
  XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY ""
)

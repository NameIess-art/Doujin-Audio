# Project-level configuration.
cmake_minimum_required(VERSION 3.19)
project(doujin_audio LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "doujin_audio")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)
add_definitions(-D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# media_kit's minimal binary omits the audio filters used by this application.
# Keep its rendering SDK, and install the complete libmpv with the same ABI.
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../tool/windows_dependencies.json" WINDOWS_DEPENDENCIES)
string(JSON MPV_URL GET "${WINDOWS_DEPENDENCIES}" mpv url)
string(JSON MPV_SHA256 GET "${WINDOWS_DEPENDENCIES}" mpv sha256)
string(JSON MPV_VERSION GET "${WINDOWS_DEPENDENCIES}" mpv version)
set(MPV_ARCHIVE "${CMAKE_BINARY_DIR}/mpv-full-${MPV_VERSION}.7z")
set(MPV_DIRECTORY "${CMAKE_BINARY_DIR}/mpv-full-${MPV_VERSION}")
if(NOT EXISTS "${MPV_ARCHIVE}")
  file(DOWNLOAD "${MPV_URL}" "${MPV_ARCHIVE}.part" EXPECTED_HASH "SHA256=${MPV_SHA256}" TLS_VERIFY ON TIMEOUT 600)
  file(RENAME "${MPV_ARCHIVE}.part" "${MPV_ARCHIVE}")
endif()
file(SHA256 "${MPV_ARCHIVE}" MPV_ACTUAL_SHA256)
if(NOT MPV_ACTUAL_SHA256 STREQUAL MPV_SHA256)
  message(FATAL_ERROR "Complete libmpv archive failed SHA256 verification")
endif()
file(ARCHIVE_EXTRACT INPUT "${MPV_ARCHIVE}" DESTINATION "${MPV_DIRECTORY}")
install(FILES "${MPV_DIRECTORY}/libmpv-2.dll" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
string(JSON FFMPEG_VERSION GET "${WINDOWS_DEPENDENCIES}" ffmpeg version)
set(FFMPEG_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../.dart_tool/windows_dependencies/ffmpeg-${FFMPEG_VERSION}-essentials_build/bin")
if(NOT EXISTS "${FFMPEG_DIRECTORY}/ffprobe.exe")
  message(FATAL_ERROR "Run tool/build_windows.bat -PrepareOnly to prepare the bundled FFmpeg tools")
endif()
install(FILES "${FFMPEG_DIRECTORY}/ffmpeg.exe" "${FFMPEG_DIRECTORY}/ffprobe.exe"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/tools" COMPONENT Runtime)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Keep Android's system SQLite configuration while bundling Windows explicitly.
string(JSON SQLITE_VERSION GET "${WINDOWS_DEPENDENCIES}" sqlite version)
string(JSON SQLITE_SHA256 GET "${WINDOWS_DEPENDENCIES}" sqlite sha256)
set(SQLITE_DLL "${CMAKE_CURRENT_SOURCE_DIR}/../.dart_tool/windows_dependencies/sqlite3-${SQLITE_VERSION}.dll")
if(NOT EXISTS "${SQLITE_DLL}")
  message(FATAL_ERROR "Run tool/build_windows.bat -PrepareOnly to prepare SQLite")
endif()
file(SHA256 "${SQLITE_DLL}" SQLITE_ACTUAL_SHA256)
if(NOT SQLITE_ACTUAL_SHA256 STREQUAL SQLITE_SHA256)
  message(FATAL_ERROR "SQLite failed SHA256 verification")
endif()
install(FILES "${SQLITE_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" RENAME sqlite3.dll COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

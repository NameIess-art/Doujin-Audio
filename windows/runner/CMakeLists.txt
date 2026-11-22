cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "desktop/desktop_integration.cpp"
  "desktop/media_controls.cpp"
  "desktop/subtitle_window.cpp"
  "desktop/scheduled_tasks.cpp"
  "desktop/network_proxy.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
# The runner relies on C++ exceptions (std::invalid_argument, C++/WinRT) under
# /EHsc. Remove _HAS_EXCEPTIONS=0 from the runner target so STL errors throw
# instead of terminating the process, without changing plugin targets.
get_target_property(RUNNER_COMPILE_DEFINITIONS ${BINARY_NAME} COMPILE_DEFINITIONS)
if(RUNNER_COMPILE_DEFINITIONS)
  list(REMOVE_ITEM RUNNER_COMPILE_DEFINITIONS "_HAS_EXCEPTIONS=0")
  set_target_properties(${BINARY_NAME} PROPERTIES COMPILE_DEFINITIONS "${RUNNER_COMPILE_DEFINITIONS}")
endif()

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(${BINARY_NAME} PRIVATE "_WIN32_WINNT=0x0A00")
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE windowsapp shell32 taskschd comsuppw advapi32)
target_link_libraries(${BINARY_NAME} PRIVATE winhttp shlwapi comctl32)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

cmake_minimum_required(VERSION 3.21)

project(Quicksilver VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Network WebSockets Widgets Test)
qt_standard_project_setup()

if(MSVC)
  add_compile_options(/W4 /permissive- /utf-8)
endif()

# --- Core library: protocol, backend process, connection policy (no widgets) ---
set(QS_PLATFORM_SOURCES)
if(WIN32)
  list(APPEND QS_PLATFORM_SOURCES src/platform/process_job_win.cpp src/platform/child_stdin_win.cpp)
else()
  list(APPEND QS_PLATFORM_SOURCES src/platform/process_job_stub.cpp src/platform/child_stdin_stub.cpp)
endif()

add_library(quicksilver_core STATIC
  src/core/app_log.cpp
  src/core/app_log.h
  src/core/backend_connection.cpp
  src/core/backend_connection.h
  src/core/backend_locator.cpp
  src/core/backend_locator.h
  src/core/backend_process.cpp
  src/core/backend_process.h
  src/core/protocol_client.cpp
  src/core/protocol_client.h
  src/core/protocol_codec.cpp
  src/core/protocol_codec.h
  src/platform/child_stdin.h
  src/platform/process_job.h
  ${QS_PLATFORM_SOURCES}
)
target_include_directories(quicksilver_core PUBLIC src)
target_link_libraries(quicksilver_core PUBLIC Qt6::Core Qt6::Network Qt6::WebSockets)
target_compile_definitions(quicksilver_core PUBLIC
  QS_CLIENT_VERSION="${PROJECT_VERSION}"
  # Dev fallback for finding backend/ when the exe isn't run from the repo.
  QS_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
)

# --- The app ---
qt_add_executable(Quicksilver WIN32
  src/main.cpp
  src/ui/command_center_window.cpp
  src/ui/command_center_window.h
)
target_link_libraries(Quicksilver PRIVATE quicksilver_core Qt6::Widgets)

# Copy the Qt runtime next to the exe after each build so it runs by double-click.
option(QS_DEPLOY_QT "Run windeployqt after building Quicksilver.exe" ON)
if(WIN32 AND QS_DEPLOY_QT)
  get_target_property(_qmake Qt6::qmake IMPORTED_LOCATION)
  get_filename_component(QS_QT_BIN "${_qmake}" DIRECTORY)
  add_custom_command(TARGET Quicksilver POST_BUILD
    COMMAND "${QS_QT_BIN}/windeployqt.exe" --no-translations --no-compiler-runtime
            --no-system-d3d-compiler --no-opengl-sw --verbose 0 "$<TARGET_FILE:Quicksilver>"
    COMMENT "windeployqt Quicksilver.exe"
    VERBATIM)
endif()

# --- Tests (Qt Test, run with ctest) ---
enable_testing()
add_subdirectory(tests)

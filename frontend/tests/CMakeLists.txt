get_target_property(_qmake Qt6::qmake IMPORTED_LOCATION)
get_filename_component(QS_QT_BIN "${_qmake}" DIRECTORY)

# One executable per test case. Each test names the requirement IDs it covers.
function(qs_add_test name)
  cmake_parse_arguments(T "" "TIMEOUT" "LABELS" ${ARGN})
  qt_add_executable(${name} ${name}.cpp)
  target_link_libraries(${name} PRIVATE quicksilver_core Qt6::Test)
  add_test(NAME ${name} COMMAND ${name})
  if(NOT T_TIMEOUT)
    set(T_TIMEOUT 60)
  endif()
  set_tests_properties(${name} PROPERTIES
    TIMEOUT ${T_TIMEOUT}
    LABELS "${T_LABELS}"
    # Qt DLLs come from the Qt install; no deploy step needed for tests.
    ENVIRONMENT_MODIFICATION "PATH=path_list_prepend:${QS_QT_BIN};QT_QPA_PLATFORM=set:offscreen")
endfunction()

qs_add_test(tst_protocol_codec LABELS unit)
qs_add_test(tst_protocol_client LABELS unit)
qs_add_test(tst_backend_locator LABELS unit)
qs_add_test(tst_process_job LABELS unit)
# Boots the real backend (erl + mix, offline). Skips itself if Erlang/Elixir or
# backend/ can't be found. Exclude with: ctest -LE integration
qs_add_test(tst_backend_e2e LABELS integration TIMEOUT 240)
target_compile_definitions(tst_backend_e2e PRIVATE
  QS_BACKEND_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../backend")

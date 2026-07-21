cmake_minimum_required(VERSION 3.10)
project(go2_action_helper)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(UNITREE_SDK_DIR "/home/unitree/Downloads/sdk/unitree_sdk2" CACHE PATH "Unitree SDK2 root")
include_directories(
  ${UNITREE_SDK_DIR}/include
  ${UNITREE_SDK_DIR}/thirdparty/include
  ${UNITREE_SDK_DIR}/thirdparty/include/ddscxx
)
link_directories(
  ${UNITREE_SDK_DIR}/thirdparty/lib/aarch64
  ${UNITREE_SDK_DIR}/lib/aarch64
)

function(configure_unitree_target target)
  target_link_libraries(${target} unitree_sdk2 ddsc ddscxx pthread)
  set_target_properties(${target} PROPERTIES
    BUILD_RPATH "${UNITREE_SDK_DIR}/thirdparty/lib/aarch64;${UNITREE_SDK_DIR}/lib/aarch64"
    INSTALL_RPATH "${UNITREE_SDK_DIR}/thirdparty/lib/aarch64;${UNITREE_SDK_DIR}/lib/aarch64"
  )
endfunction()

add_executable(go2_action_helper go2_action_helper.cpp)
configure_unitree_target(go2_action_helper)

add_executable(go2_lidar_navigator
  go2_lidar_navigator.cpp
  go2_local_planner.cpp
)
configure_unitree_target(go2_lidar_navigator)

add_executable(go2_camera_probe go2_camera_probe.cpp)
configure_unitree_target(go2_camera_probe)

enable_testing()
add_executable(go2_local_planner_test
  go2_local_planner_test.cpp
  go2_local_planner.cpp
)
add_test(NAME go2_local_planner_test COMMAND go2_local_planner_test)

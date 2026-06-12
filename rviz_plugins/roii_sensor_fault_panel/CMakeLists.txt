cmake_minimum_required(VERSION 3.8)
project(roii_sensor_fault_panel)

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(rviz_common REQUIRED)
find_package(std_msgs REQUIRED)
find_package(pluginlib REQUIRED)
find_package(Qt5 REQUIRED COMPONENTS Widgets)

set(CMAKE_AUTOMOC ON)
qt5_wrap_cpp(MOC_FILES include/roii_sensor_fault_panel/roii_sensor_fault_panel.hpp)

add_library(${PROJECT_NAME} SHARED
  src/roii_sensor_fault_panel.cpp
  ${MOC_FILES})
target_include_directories(${PROJECT_NAME} PUBLIC include)
ament_target_dependencies(${PROJECT_NAME} rclcpp rviz_common std_msgs pluginlib)
target_link_libraries(${PROJECT_NAME} Qt5::Widgets)

install(TARGETS ${PROJECT_NAME} DESTINATION lib)
install(FILES plugin_description.xml DESTINATION share/${PROJECT_NAME})
install(DIRECTORY include/ DESTINATION include)

pluginlib_export_plugin_description_file(rviz_common plugin_description.xml)
ament_package()

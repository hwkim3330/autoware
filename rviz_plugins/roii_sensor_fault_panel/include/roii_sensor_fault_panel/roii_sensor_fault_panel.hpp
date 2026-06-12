// ROii 4-LiDAR health + fault-injection RViz panel.
// UI + command publishing ONLY: fault logic lives in roii_lidar_fault_injector.py,
// health logic in roii_lidar_health_monitor.py.
#ifndef ROII_SENSOR_FAULT_PANEL_HPP_
#define ROII_SENSOR_FAULT_PANEL_HPP_

#include <map>
#include <string>

#include <QLabel>
#include <QPushButton>
#include <QTimer>

#include <rclcpp/rclcpp.hpp>
#include <rviz_common/panel.hpp>
#include <std_msgs/msg/string.hpp>

namespace roii_sensor_fault_panel
{

struct SensorRow
{
  QLabel * status{nullptr};
  QLabel * hz{nullptr};
  QLabel * stamp{nullptr};
  QLabel * tf{nullptr};
  QLabel * points{nullptr};
};

class ROiiSensorFaultPanel : public rviz_common::Panel
{
  Q_OBJECT

public:
  explicit ROiiSensorFaultPanel(QWidget * parent = nullptr);
  void onInitialize() override;

private Q_SLOTS:
  void sendCommand(const QString & json);
  void refresh();

private:
  void healthCallback(const std_msgs::msg::String::SharedPtr msg);
  void applyHealthJson(const std::string & data);
  QWidget * makeSensorBox(const QString & title, const std::string & key);

  rclcpp::Node::SharedPtr node_;
  rclcpp::Publisher<std_msgs::msg::String>::SharedPtr cmd_pub_;
  rclcpp::Publisher<std_msgs::msg::String>::SharedPtr emergency_pub_;
  rclcpp::Subscription<std_msgs::msg::String>::SharedPtr health_sub_;
  rclcpp::executors::SingleThreadedExecutor::SharedPtr executor_;
  QTimer * spin_timer_{nullptr};

  std::map<std::string, SensorRow> rows_;
  QLabel * aggregate_{nullptr};
  std::string emergency_topic_;  // configurable; empty = disabled
};

}  // namespace roii_sensor_fault_panel

#endif  // ROII_SENSOR_FAULT_PANEL_HPP_

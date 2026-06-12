#include "roii_sensor_fault_panel/roii_sensor_fault_panel.hpp"

#include <QGridLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QVBoxLayout>

#include <pluginlib/class_list_macros.hpp>

namespace roii_sensor_fault_panel
{

namespace
{
const char * kSensors[4] = {"front_g32", "rear_g32", "left_pandar", "right_pandar"};
const char * kTitles[4] = {"Front G32", "Rear G32", "Left Pandar", "Right Pandar"};

// tiny JSON value extractor (flat string/number fields only) -- avoids a
// nlohmann dependency. Returns "" when key absent.
std::string jsonGet(const std::string & src, const std::string & key)
{
  const std::string pat = "\"" + key + "\":";
  auto p = src.find(pat);
  if (p == std::string::npos) {return "";}
  p += pat.size();
  while (p < src.size() && (src[p] == ' ')) {p++;}
  if (p >= src.size()) {return "";}
  if (src[p] == '"') {
    auto e = src.find('"', p + 1);
    return e == std::string::npos ? "" : src.substr(p + 1, e - p - 1);
  }
  auto e = src.find_first_of(",}", p);
  return e == std::string::npos ? "" : src.substr(p, e - p);
}

std::string jsonObject(const std::string & src, const std::string & key)
{
  const std::string pat = "\"" + key + "\":";
  auto p = src.find(pat);
  if (p == std::string::npos) {return "";}
  p = src.find('{', p);
  if (p == std::string::npos) {return "";}
  int depth = 0;
  for (size_t i = p; i < src.size(); ++i) {
    if (src[i] == '{') {depth++;}
    if (src[i] == '}') {
      depth--;
      if (depth == 0) {return src.substr(p, i - p + 1);}
    }
  }
  return "";
}

void paintStatus(QLabel * l, const QString & st)
{
  QString color = "#9e9e9e";  // STALE/UNKNOWN gray
  if (st == "OK") {color = "#2db300";} else if (st == "WARN" || st == "DEGRADED") {
    color = "#e6b800";
  } else if (st == "ERROR") {color = "#d32f2f";}
  l->setText(st.isEmpty() ? "UNKNOWN" : st);
  l->setStyleSheet(
    QString("QLabel{background:%1;color:white;font-weight:bold;"
            "padding:2px 8px;border-radius:4px;}").arg(color));
}
}  // namespace

ROiiSensorFaultPanel::ROiiSensorFaultPanel(QWidget * parent)
: rviz_common::Panel(parent)
{
  auto * root = new QVBoxLayout(this);

  aggregate_ = new QLabel("UNKNOWN");
  auto * top = new QHBoxLayout();
  top->addWidget(new QLabel("<b>ROii LiDAR suite</b>"));
  top->addStretch();
  top->addWidget(new QLabel("aggregate:"));
  top->addWidget(aggregate_);
  paintStatus(aggregate_, "");
  root->addLayout(top);

  for (int i = 0; i < 4; ++i) {
    root->addWidget(makeSensorBox(kTitles[i], kSensors[i]));
  }

  // Global controls
  auto * box = new QGroupBox("Global");
  auto * g = new QHBoxLayout(box);
  auto addBtn = [&](const char * label, const QString & json) {
      auto * b = new QPushButton(label);
      connect(b, &QPushButton::clicked, this, [this, json]() {sendCommand(json);});
      g->addWidget(b);
    };
  addBtn("All Normal", R"({"sensor":"all","mode":"normal"})");
  addBtn("All Drop", R"({"sensor":"all","mode":"drop","duration":10.0})");
  addBtn("All Stamp Err",
    R"({"sensor":"all","mode":"stamp_offset","offset_sec":-5.0,"duration":10.0})");
  auto * em = new QPushButton("Trigger Emergency");
  em->setStyleSheet("QPushButton{background:#d32f2f;color:white;font-weight:bold;}");
  connect(em, &QPushButton::clicked, this, [this]() {
      if (!emergency_topic_.empty() && emergency_pub_) {
        std_msgs::msg::String m;
        m.data = "emergency";
        emergency_pub_->publish(m);
      }
    });
  g->addWidget(em);
  auto * rf = new QPushButton("Refresh");
  connect(rf, &QPushButton::clicked, this, &ROiiSensorFaultPanel::refresh);
  g->addWidget(rf);
  root->addWidget(box);
  root->addStretch();
}

QWidget * ROiiSensorFaultPanel::makeSensorBox(const QString & title, const std::string & key)
{
  auto * box = new QGroupBox(title);
  auto * v = new QVBoxLayout(box);

  auto * info = new QHBoxLayout();
  SensorRow row;
  row.status = new QLabel("UNKNOWN");
  paintStatus(row.status, "");
  row.hz = new QLabel("hz: -");
  row.stamp = new QLabel("stamp: -");
  row.tf = new QLabel("tf: -");
  row.points = new QLabel("pts: -");
  info->addWidget(row.status);
  info->addWidget(row.hz);
  info->addWidget(row.stamp);
  info->addWidget(row.tf);
  info->addWidget(row.points);
  info->addStretch();
  v->addLayout(info);
  rows_[key] = row;

  auto * btns = new QHBoxLayout();
  const QString k = QString::fromStdString(key);
  auto addBtn = [&](const char * label, const QString & json) {
      auto * b = new QPushButton(label);
      connect(b, &QPushButton::clicked, this, [this, json]() {sendCommand(json);});
      btns->addWidget(b);
    };
  addBtn("Normal", QString(R"({"sensor":"%1","mode":"normal"})").arg(k));
  addBtn("Drop", QString(R"({"sensor":"%1","mode":"drop","duration":10.0})").arg(k));
  addBtn("Delay",
    QString(R"({"sensor":"%1","mode":"delay","delay_ms":500,"duration":10.0})").arg(k));
  addBtn("Stamp Err",
    QString(R"({"sensor":"%1","mode":"stamp_offset","offset_sec":-5.0,"duration":10.0})").arg(k));
  addBtn("Low Pts",
    QString(R"({"sensor":"%1","mode":"downsample","ratio":0.1,"duration":10.0})").arg(k));
  v->addLayout(btns);
  return box;
}

void ROiiSensorFaultPanel::onInitialize()
{
  node_ = std::make_shared<rclcpp::Node>("roii_sensor_fault_panel");
  cmd_pub_ = node_->create_publisher<std_msgs::msg::String>(
    "/roii/fault_injector/command", 10);
  // emergency target is configurable; empty by default (Phase C wires it)
  emergency_topic_ = node_->declare_parameter<std::string>("emergency_topic", "");
  if (!emergency_topic_.empty()) {
    emergency_pub_ = node_->create_publisher<std_msgs::msg::String>(emergency_topic_, 1);
  }
  health_sub_ = node_->create_subscription<std_msgs::msg::String>(
    "/roii/lidar_health", 10,
    std::bind(&ROiiSensorFaultPanel::healthCallback, this, std::placeholders::_1));

  executor_ = std::make_shared<rclcpp::executors::SingleThreadedExecutor>();
  executor_->add_node(node_);
  spin_timer_ = new QTimer(this);
  connect(spin_timer_, &QTimer::timeout, this, [this]() {executor_->spin_some();});
  spin_timer_->start(100);
}

void ROiiSensorFaultPanel::sendCommand(const QString & json)
{
  if (!cmd_pub_) {return;}
  std_msgs::msg::String m;
  m.data = json.toStdString();
  cmd_pub_->publish(m);
}

void ROiiSensorFaultPanel::refresh()
{
  for (auto & [k, row] : rows_) {
    paintStatus(row.status, "");
  }
  paintStatus(aggregate_, "");
}

void ROiiSensorFaultPanel::healthCallback(const std_msgs::msg::String::SharedPtr msg)
{
  applyHealthJson(msg->data);
}

void ROiiSensorFaultPanel::applyHealthJson(const std::string & data)
{
  const std::string agg = jsonGet(data, "aggregate");
  paintStatus(aggregate_, QString::fromStdString(agg));
  const std::string sensors = jsonObject(data, "sensors");
  if (sensors.empty()) {return;}
  for (auto & [key, row] : rows_) {
    const std::string s = jsonObject(sensors, key);
    if (s.empty()) {paintStatus(row.status, ""); continue;}
    paintStatus(row.status, QString::fromStdString(jsonGet(s, "status")));
    row.hz->setText(QString("hz: %1").arg(QString::fromStdString(jsonGet(s, "hz"))));
    row.stamp->setText(QString("stampΔ: %1s").arg(
        QString::fromStdString(jsonGet(s, "stamp_diff"))));
    row.tf->setText(QString("tf: %1").arg(jsonGet(s, "tf") == "true" ? "OK" : "MISSING"));
    row.points->setText(QString("pts: %1").arg(
        QString::fromStdString(jsonGet(s, "points"))));
  }
}

}  // namespace roii_sensor_fault_panel

PLUGINLIB_EXPORT_CLASS(roii_sensor_fault_panel::ROiiSensorFaultPanel, rviz_common::Panel)

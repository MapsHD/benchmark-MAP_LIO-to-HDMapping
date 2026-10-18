#!/usr/bin/env python3
"""Preflight check for the MAP_LIO benchmark run.

MAP_LIO reads the LiDAR and IMU topics named in its parameter file
(common/lid_topic, common/imu_topic) straight from the bag. If either is
missing it processes nothing and the run records no output, so the check
stops the run first (exit code 42, the run script then skips the conversion).

MAP_LIO's input is the Hesai driver's point format: x, y, z, intensity and a
float64 per-point 'timestamp' (absolute, seconds). Without that field every
point gets the same time and the scans are not deskewed; this only warns.

Usage: map_lio_preflight.py <parameter_file.yaml> <input.bag>
"""

import sys

import rosbag
import yaml

FLOAT64 = 8  # sensor_msgs/PointField datatype


def main():
    config_path, bag_path = sys.argv[1], sys.argv[2]
    with open(config_path) as f:
        common = yaml.safe_load(f)["common"]
    lid_topic, imu_topic = common["lid_topic"], common["imu_topic"]
    print(f"[preflight] parameter file: {config_path}")
    print(f"[preflight] LiDAR topic: {lid_topic}  IMU topic: {imu_topic}")

    bag = rosbag.Bag(bag_path)
    topics = bag.get_type_and_topic_info().topics

    ok = True
    for name, msg_type in ((lid_topic, "sensor_msgs/PointCloud2"), (imu_topic, "sensor_msgs/Imu")):
        info = topics.get(name)
        if info is None or info.msg_type != msg_type:
            found = info.msg_type if info else "not in the bag"
            print(f"[preflight] ERROR: {name} must be {msg_type} ({found}).")
            ok = False
        else:
            print(f"[preflight] {name}: {info.message_count} msgs ({msg_type})")
    if not ok:
        for msg_type in ("sensor_msgs/PointCloud2", "sensor_msgs/Imu"):
            names = [t for t, i in topics.items() if i.msg_type == msg_type]
            print(f"[preflight] {msg_type} topics in this bag: {', '.join(names) or '(none)'}")
        print("[preflight] Set common/lid_topic and common/imu_topic in the parameter file (CONFIG_FILE).")
        sys.exit(42)

    for _, msg, _ in bag.read_messages(topics=[lid_topic]):
        fields = {f.name: f.datatype for f in msg.fields}
        if fields.get("timestamp") == FLOAT64:
            print("[preflight] per-point float64 'timestamp' field present")
        else:
            print(f"[preflight] WARNING: {lid_topic} has no float64 per-point 'timestamp' field "
                  f"(fields: {', '.join(fields)}). MAP_LIO reads the Hesai point format; "
                  "without it the scans are not deskewed.")
        break
    bag.close()


if __name__ == "__main__":
    main()

FROM ubuntu:20.04

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# ── Base tools ────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg2 \
    lsb-release \
    software-properties-common \
    build-essential \
    cmake \
    git \
    apt-transport-https \
    ca-certificates \
    wget \
    libeigen3-dev \
    libpcl-dev \
    libyaml-cpp-dev \
    libgeographic-dev \
    geographiclib-tools \
    libgoogle-glog-dev \
    libgflags-dev \
    libsuitesparse-dev \
    nlohmann-json3-dev \
    tmux \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ── ROS 1 Noetic ─────────────────────────────────────────────────────────────
# Package list follows MAP_LIO's own docker_map/Dockerfile.
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
    http://packages.ros.org/ros/ubuntu $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/ros.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-noetic-desktop-full \
    ros-noetic-eigen-conversions \
    ros-noetic-tf \
    ros-noetic-tf2-ros \
    ros-noetic-pcl-ros \
    ros-noetic-gps-common \
    ros-noetic-geodesy \
    ros-noetic-robot-state-publisher \
    ros-noetic-joint-state-publisher \
    ros-noetic-hector-trajectory-server \
    ros-noetic-hector-map-server \
    python3-rosdep \
    python3-catkin-tools \
    && rm -rf /var/lib/apt/lists/*

# ── rosbags (used to convert ROS 2 bags to ROS 1, if needed) ─────────────────
RUN pip3 install --no-cache-dir "rosbags==0.9.22"

# ── Sophus ───────────────────────────────────────────────────────────────────
# MAP_LIO pins the non-templated Sophus (Sophus::SE3) as third_party/Sophus at
# commit a621ff2e, but its repository has no .gitmodules entry for it, so a
# recursive clone leaves that folder empty. The same commit is fetched here.
# Its so2.cpp assigns to std::complex::real()/imag(), which newer compilers
# reject; the one constructor line is rewritten to the equivalent assignment.
# This Sophus installs headers and library but not its SophusConfig.cmake,
# which stays in its build folder; the folder is therefore kept and passed to
# catkin_make as Sophus_DIR.
RUN git clone https://github.com/strasdat/Sophus.git /opt/Sophus && \
    cd /opt/Sophus && \
    git checkout a621ff2e56c56c839a6c40418d42c3c254424b5c && \
    sed -i 's/unit_complex_\.real() = 1\.;/unit_complex_ = std::complex<double>(1., 0.);/; /unit_complex_\.imag() = 0\.;/d' sophus/so2.cpp && \
    mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON && \
    make -j$(nproc) && \
    make install && \
    ldconfig && \
    test -f /opt/Sophus/build/SophusConfig.cmake

# ── Build catkin workspace (MAP_LIO + converter) ─────────────────────────────
WORKDIR /ros_ws

COPY ./src/MAP_LIO              ./src/MAP_LIO
COPY ./src/map-lio-to-hdmapping ./src/map-lio-to-hdmapping

# Benchmark launch (bag file and parameter file as roslaunch args) and the
# benchmark parameter files (next to MAP_LIO's own hesai.yaml) added into the
# map_lio package; input check/conversion script used by the run script.
COPY ./overlay/launch/  ./src/MAP_LIO/launch/
COPY ./overlay/config/  ./src/MAP_LIO/config/
COPY ./overlay/scripts/ /ros_ws/scripts/

# Build MAP_LIO in lidar-inertial mode (no prior ALS map, USE_ALS=OFF, so
# LASzip/libLAS are not needed) and the converter. The final guard fails the
# image build loudly if an executable is missing.
RUN source /opt/ros/noetic/setup.bash && \
    catkin_make -DCMAKE_BUILD_TYPE=Release -DUSE_ALS=OFF -DSophus_DIR=/opt/Sophus/build -j$(nproc) && \
    test -f /ros_ws/devel/lib/map_lio/estimate_map && \
    test -f /ros_ws/devel/lib/map_lio_to_hdmapping/listener && \
    echo "[build] estimate_map and converter present"

# ── Non-root user ─────────────────────────────────────────────────────────────
ARG UID=1000
ARG GID=1000
RUN groupadd -g $GID ros && \
    useradd -m -u $UID -g $GID -s /bin/bash ros && \
    chown -R $UID:$GID /ros_ws

RUN echo "source /opt/ros/noetic/setup.bash"   >> /root/.bashrc && \
    echo "source /ros_ws/devel/setup.bash"     >> /root/.bashrc && \
    echo "source /opt/ros/noetic/setup.bash"   >> /home/ros/.bashrc && \
    echo "source /ros_ws/devel/setup.bash"     >> /home/ros/.bashrc

CMD ["bash"]

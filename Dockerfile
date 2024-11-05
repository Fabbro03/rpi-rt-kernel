FROM ubuntu:24.04

ENV LINUX_KERNEL_VERSION=6.6
ENV LINUX_KERNEL_BRANCH=stable_20240529
ENV LINUX_KERNEL_RT_PATCH=patch-6.6.30-rt30

ENV TZ=Europe/Copenhagen
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt-get update
RUN apt-get install -y git make gcc bison flex libssl-dev bc ncurses-dev kmod \
    crossbuild-essential-arm64 crossbuild-essential-armhf \
    wget zip unzip fdisk nano curl xz-utils jq

WORKDIR /rpi-kernel
RUN git clone https://github.com/raspberrypi/linux.git -b ${LINUX_KERNEL_BRANCH} --depth=1
WORKDIR /rpi-kernel/linux
RUN curl https://mirrors.edge.kernel.org/pub/linux/kernel/projects/rt/${LINUX_KERNEL_VERSION}/older/${LINUX_KERNEL_RT_PATCH}.patch.gz --output ${PATCH}.patch.gz && \
    gzip -cd /rpi-kernel/linux/${PATCH}.patch.gz | patch -p1 --verbose
RUN curl https://mirrors.edge.kernel.org/pub/linux/kernel/projects/rt/${LINUX_KERNEL_VERSION}/${LINUX_KERNEL_RT_PATCH}.patch.gz --output ${PATCH}.patch.gz && \
    gzip -cd /rpi-kernel/linux/${PATCH}.patch.gz | patch -p1 --verbose

ARG RASPIOS
ARG DEFCONFIG
ARG KERNEL
ARG CROSS_COMPILE
ARG ARCH
ARG TARGET
ARG FULL

ENV RASPIOS=${RASPIOS}
ENV KERNEL=${KERNEL}
ENV ARCH=${ARCH}
ENV TARGET=${TARGET}
ENV FULL=${FULL}

# print the args
RUN echo ${RASPIOS} ${DEFCONFIG} ${KERNEL} ${CROSS_COMPILE} ${ARCH} ${FULL}

RUN make ${DEFCONFIG}

# Disable virtualization to reduce overhead
RUN ./scripts/config --disable CONFIG_VIRTUALIZATION 

# Enable PREEMPT-RT (this enables `CONFIG_PREEMPT_RT_FULL`)
RUN ./scripts/config --enable CONFIG_PREEMPT_RT

# Disable RCU expert configuration
RUN ./scripts/config --disable CONFIG_RCU_EXPERT

# Enable RCU boosting, which allows preemption within Read-Copy-Update (RCU)
RUN ./scripts/config --enable CONFIG_RCU_BOOST

# Set RCU boost delay, adjusting how quickly boosted RCU threads run
RUN ./scripts/config --set-val CONFIG_RCU_BOOST_DELAY 500

# Enable symmetric multiprocessing for ARM
RUN [ "$ARCH" = "arm" ] && ./scripts/config --enable CONFIG_SMP || true

# Disable features known to have issues on SMP for ARM
RUN [ "$ARCH" = "arm" ] && ./scripts/config --disable CONFIG_BROKEN_ON_SMP || true

# Enable full preemptible real-time support
RUN if [FULL = "true" ]; then ./scripts/config --enable CONFIG_PREEMPT_RT_FULL; fi

# Enable high-resolution timers for precise timing
RUN if [FULL = "true" ]; then ./scripts/config --enable CONFIG_HIGH_RES_TIMERS; fi

# Set timer frequency to 1000 Hz for finer resolution
RUN if [FULL = "true" ]; then ./scripts/config --set-val CONFIG_HZ 1000; fi

# Force interrupts to run as threads for better preemption
RUN if [FULL = "true" ]; then ./scripts/config --enable CONFIG_IRQ_FORCED_THREADING; fi

RUN [ "$ARCH" = "arm64" ] && make -j$((`nproc`+1)) Image.gz modules dtbs
RUN [ "$ARCH" = "arm" ] && make -j$((`nproc`+1)) zImage modules dtbs || true

RUN echo "using raspberry pi image ${RASPIOS}"
WORKDIR /raspios

RUN export DATE=$(curl -s https://downloads.raspberrypi.org/${RASPIOS}/images/ | sed -n "s:.*${RASPIOS}-\(.*\)/</a>.*:\1:p" | tail -1) && \
    export RASPIOS_IMAGE_NAME=$(curl -s https://downloads.raspberrypi.org/${RASPIOS}/images/${RASPIOS}-${DATE}/ | sed -n "s:.*<a href=\"\(.*\).xz\">.*:\1:p" | head -n 1) && \
    echo "Downloading ${RASPIOS_IMAGE_NAME}.xz" && \
    curl https://downloads.raspberrypi.org/${RASPIOS}/images/${RASPIOS}-${DATE}/${RASPIOS_IMAGE_NAME}.xz --output ${RASPIOS}.xz && \
    xz -d ${RASPIOS}.xz

RUN mkdir /raspios/mnt && mkdir /raspios/mnt/disk && mkdir /raspios/mnt/boot && mkdir /raspios/mnt/boot/firmware
ADD build.sh ./build.sh
ADD config.txt ./
ADD userconf ./

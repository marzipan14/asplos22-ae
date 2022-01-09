# You can easily build it with the following command:
# $ docker build --tag flexos-iperf -f flexos-iperf.dockerfile .
#
# If the build fails because you are rate-limited by GitHub, generate an app
# token () and run instead:
# $ docker build --build-arg UK_KRAFT_GITHUB_TOKEN="<YOUR TOKEN>" --tag flexos-iperf
#
# and run with:
# $ docker run --privileged --security-opt seccomp:unconfined -ti flexos-iperf bash
#
# (--security-opt seccomp:unconfined to limit docker overhead)

FROM ghcr.io/project-flexos/flexos-ae-base:latest

ARG GITHUB_TOKEN=
ENV UK_KRAFT_GITHUB_TOKEN=${GITHUB_TOKEN}

COPY docker-data/build-images.sh /root/

##############
# FlexOS (KVM)

COPY docker-data/flexos-net.patch /root/
WORKDIR /root/.unikraft/apps

# build flexos with 2 mpk compartments (iperf/rest) and private stacks
RUN kraftcleanup
# The /root/flexos-net.patch patch should be merged into the flexos main tree; the only reason
# why it isn't is because it was added fairly late in the AE process and we didn't want to
# potentially create bugs in other benchmarks. Ultimately, it should improve performance everywhere.
RUN cd /root/.unikraft/unikraft && git checkout fdc605c0cc482c4d230885962d8aae1ad558157b && \
	git apply /root/flexos-net.patch
RUN sed -i "s/TCP_WND 32766/TCP_WND 65335/g" /root/.unikraft/libs/lwip/include/lwipopts.h
COPY docker-data/configs/iperf-flexos-mpk2.config /root/.unikraft/apps/iperf/.config
RUN cd iperf && make prepare && kraft -v build --no-progress --fast --compartmentalize
COPY docker-data/start-scripts/kvmflexos-start.sh /root/.unikraft/apps/iperf/kvm-start.sh
RUN cd iperf && /root/build-images.sh && rm -rf build/
RUN mv iperf iperf-mpk2-isolstack

# build flexos with 2 mpk compartments (iperf/rest) and shared stacks
RUN kraftcleanup
RUN cd /root/.unikraft/unikraft && git checkout fdc605c0cc482c4d230885962d8aae1ad558157b && \
	git apply /root/flexos-net.patch
RUN sed -i "s/TCP_WND 32766/TCP_WND 65335/g" /root/.unikraft/libs/lwip/include/lwipopts.h
RUN rm -rf /root/.unikraft/apps/iperf && cp -r iperf-mpk2-isolstack iperf-mpk2-noisolstack
RUN sed -i "s/CONFIG_LIBFLEXOS_GATE_INTELPKU_PRIVATE_STACKS=y/# CONFIG_LIBFLEXOS_GATE_INTELPKU_PRIVATE_STACKS is not set/g" \
	iperf-mpk2-noisolstack/.config
RUN sed -i "s/CONFIG_LIBFLEXOS_ENABLE_DSS=y/# CONFIG_LIBFLEXOS_ENABLE_DSS is not set/g" \
	iperf-mpk2-noisolstack/.config
RUN sed -i "s/# CONFIG_LIBFLEXOS_GATE_INTELPKU_SHARED_STACKS is not set/CONFIG_LIBFLEXOS_GATE_INTELPKU_SHARED_STACKS=y/g" \
	iperf-mpk2-noisolstack/.config
RUN cd iperf-mpk2-noisolstack && rm -rf images build
RUN cd iperf-mpk2-noisolstack && make prepare && kraft -v build --no-progress --fast --compartmentalize
RUN cd iperf-mpk2-noisolstack && /root/build-images.sh && rm -rf build/

# build flexos with 2 ept compartments (iperf/rest)
RUN kraftcleanup
RUN sed -i "s/TCP_WND 32766/TCP_WND 65335/g" /root/.unikraft/libs/lwip/include/lwipopts.h
RUN cd /root/.unikraft/unikraft && git checkout fdc605c0cc482c4d230885962d8aae1ad558157b && \
	git apply /root/flexos-net.patch && git apply /root/ept2-tmpfix.patch
COPY docker-data/configs/iperf-flexos-ept2.config iperf/.config
COPY docker-data/configs/kraft.yaml.ept2 iperf/kraft.yaml
RUN cd iperf && /root/build-images.sh && rm -rf build/
COPY docker-data/start-scripts/kvmflexosept2-start.sh iperf/kvm-start.sh
RUN mv iperf iperf-ept2

# build flexos with no compartments
RUN kraftcleanup
RUN cd /root/.unikraft/unikraft && git checkout fdc605c0cc482c4d230885962d8aae1ad558157b && \
	git apply /root/flexos-net.patch
# There is a bug in the FlexOS toolchain that causes instable measurements with the fcalls
# backend. It will be fixed for the 0.2 release. For now, this workaround should be equivalent
# to a proper fix in the toolchain.
RUN cd ../libs && rm -rf lwip && git clone https://github.com/unikraft/lib-lwip.git && mv lib-lwip lwip
RUN cd ../libs/lwip && git checkout 3c85bd46a3f764039d8f6e3128c8f5d7096dbd13
RUN sed -i "s/TCP_WND 32766/TCP_WND 65335/g" ../libs/lwip/include/lwipopts.h
RUN mv /root/.unikraft/apps/iperf /root/.unikraft/apps/iperf-fcalls
COPY docker-data/configs/iperf-flexos-fcalls.config /root/.unikraft/apps/iperf-fcalls/.config
COPY docker-data/configs/kraft.yaml.fcalls /root/.unikraft/apps/iperf-fcalls/kraft.yaml
RUN cd iperf-fcalls && make prepare && kraft -v build --no-progress --fast --compartmentalize
RUN cd iperf-fcalls && /root/build-images.sh && rm -rf build/
COPY docker-data/start-scripts/kvmflexos-start.sh /root/.unikraft/apps/iperf-fcalls/kvm-start.sh

RUN mv /root/.unikraft /root/flexos

##############
# Unikraft 0.5 (KVM and linuxu)
# Performance is similar to Unikraft 0.4, so omit it.

WORKDIR /root/unikraft-mainline/libs

# page table support patch
COPY docker-data/unikraft-pagetable.patch /tmp/pt.patch
RUN cd /root/unikraft-mainline/unikraft && git apply /tmp/pt.patch --ignore-whitespace

RUN git clone https://github.com/unikraft/lib-newlib.git
RUN cd lib-newlib && git checkout ddc25cf1f361e33d1003ce1842212e8ff37b1e08

RUN git clone https://github.com/unikraft/lib-pthread-embedded.git
RUN cd lib-pthread-embedded && git checkout 2dd71294ab5fac328e62932992550405c866c7e8

RUN cp -r /root/flexos/libs/iperf lib-iperf
# use unikraft baseline branch
RUN cd lib-iperf && git clean -xdf && git checkout . && git checkout 120324e7986f8fb7a90debd7637708c8485de519

RUN git clone https://github.com/unikraft/lib-tlsf.git
RUN cd lib-tlsf && git checkout ae4f7402a2c5ee6040dab799b397537177306cc9

RUN git clone https://github.com/unikraft/lib-lwip.git
RUN cd lib-lwip && git checkout 3c85bd46a3f764039d8f6e3128c8f5d7096dbd13
RUN sed -i "s/TCP_WND 32766/TCP_WND 65335/g" lib-lwip/include/lwipopts.h

WORKDIR /root/unikraft-mainline/apps

RUN cp -r /root/flexos/apps/iperf-fcalls/ app-iperf
# use unikraft baseline branch
RUN cd app-iperf && git clean -xdf && git checkout . && git checkout 7cda87c1b39398b7338a01bb59bdefdcc03efd73
COPY docker-data/configs/iperf-unikraft.config app-iperf/.config
RUN cd app-iperf && /root/build-images.sh && rm -rf build/
RUN cp /root/flexos/apps/iperf-fcalls/kvm-start.sh app-iperf/kvm-start.sh

##############
# Finish

WORKDIR /root

COPY docker-data/run.sh .
RUN chmod u+x run.sh

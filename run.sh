#! /bin/bash
#
# Copyright (C) 2015 Flavio Leitner <fbl@redhat.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation; either version 2.1 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# The goal of this script is to measure the performance when
# using Open vSwitch's internal ports and Linux veth devices
# to connect network namespaces like conntainers do. For that,
# it will create a pair of namespaces and establish a network
# between them using Open vSwitch bridge and then execute some
# netperf tests in the testing environment.
#
# Of course, measuring performance is a complex task and this
# script does some work to compare apples to apples and also
# to get more stable numbers, but still it's far from being
# complete.  It's also limited to netperf tests which is just
# one artificial way of measure throughput and latency.

# Number of rounds for each netperf test
NETPERF_TEST_ROUNDS=5

# Number of seconds for each netperf test
NETPERF_TEST_LEN=60

# UDP packet sizes to test
PKTSIZES="1 64 256 1024 1400"

#
# You shouldn't need to modify below this point
#


netperf_url="ftp://ftp.netperf.org/netperf/"
netperf_tarball="netperf-2.6.0.tar.gz"
netperf_cmd=""
netperf_nr_threads=1

LOGDIR=""
cpu_get_cstates() {
	grep -q 'max_cstates=1' /proc/cmdline
	if [ $? -ne 0 ]; then
		echo "pass processor.max_cstates=1 to kernel"
		exit 1
	fi
}

cpu_set_gov() {
	local gov=$1
	for sysfs in /sys/devices/system/cpu/*/cpufreq/scaling_governor
	do
		echo $gov > $sysfs
	done
}

netperf_deploy() {
	which netperf &> /dev/null
	if [ $? -ne 0 ]; then
		echo "Installing netperf"
		rpm -q --quiet wget
		if [ $? -ne 0 ]; then
			yum install wget -y
		fi
		
		which wget &> /dev/null
		if [ $? -ne 0 ]; then
			echo "fail to install wget"
			exit -1
		fi

		WORKDIR=$(mktemp --tmpdir -d netperf.XXXXXXXX)
		if test ! -d ${WORKDIR}; then
			echo "fail to create tmpdir"
			exit -1
		fi

		pushd $(pwd)
		cd ${WORKDIR}
		wget "${netperf_url}/${netperf_tarball}"
		if [ $? -ne 0]; then
			echo "fail to download ${netperf_tarball}"
			popd
			exit -1
		fi

		tar zxfv ${netperf_tarball}
		cd netperf-2.6.0
		./configure
		if [ $? -ne 0 ]; then
			popd
			exit -1
		fi

		make
		if [ $? -ne 0 ]; then
			popd
			exit -1
		fi

		make install
		if [ $? -ne 0 ]; then
			popd
			exit -1
		fi
		popd
	else
		echo "netperf is available"
	fi
}

netperf_init() {
	if [ -f "super_netperf.sh" ]; then
		nrcpus=$(grep processor /proc/cpuinfo | wc -l)
		netperf_nr_threads=$(expr $nrcpus / 2)
		cp -f super_netperf.sh /tmp/super_netperf.sh
		netperf_cmd="/tmp/super_netperf.sh"
		echo "using super_netperf with threads enabled"
	else
		echo "using netperf directly is not supported yet"
		exit -1
	fi
}

netperf_run_tests() {
	local logprefix="${1}"
	local nsname="${2}"
	local target_ip="${3}"
	local nr_threads=${4}
	local len=${5}


	echo -n "${logprefix} with ${nr_threads} threads progress: ."
	sleep 5
	echo -n "."
	ip netns exec ${nsname} \
		${netperf_cmd} ${nr_threads} -t TCP_STREAM -H ${target_ip} -l ${len} \
		>> ${LOGDIR}/${logprefix}-tcp_stream.log

	echo -n "."
	sleep 5
	echo -n "."
	for pktsz in ${PKTSIZES}; do
		echo -n "."
		echo -n "pktsize: $pktsz: " >> ${LOGDIR}/${logprefix}-udp_stream.log
		ip netns exec ${nsname} \
			${netperf_cmd} ${nr_threads} -t UDP_STREAM -H ${target_ip} -l ${len} \
			-- -m ${pktsz} -D >> ${LOGDIR}/${logprefix}-udp_stream.log
	done
	echo -n "."
	echo -n "pktsize: none: " >> ${LOGDIR}/${logprefix}-udp_stream.log
	ip netns exec ${nsname} \
		${netperf_cmd} ${nr_threads} -t UDP_STREAM -H ${target_ip} -l ${len} \
		>> ${LOGDIR}/${logprefix}-udp_stream.log

	echo -n "."
	sleep 5
	echo -n "."
	ip netns exec ${nsname} \
		${netperf_cmd} ${nr_threads} -t TCP_RR -H ${target_ip} -l ${len} \
		>> ${LOGDIR}/${logprefix}-tcp_rr.log
	echo -n "."
	echo ""

	uname -a >> ${LOGDIR}/uname
}

netperf_run_veth() {
	local nsname="${1}"
	local tgtname="ns${2}"
	local target_ip="10.100.0.${2}"
	local len="${3}"

	netperf_run_tests "veth-${nsname}-${tgtname}-t1" "${nsname}" "${target_ip}" "1" "${len}"
	netperf_run_tests "veth-${nsname}-${tgtname}-t${netperf_nr_threads}" "${nsname}" "${target_ip}" "${netperf_nr_threads}" "${len}"
}

netperf_run_int() {
	local nsname="${1}"
	local tgtname="ns${2}"
	local target_ip="10.200.0.${2}"
	local len="${3}"

	netperf_run_tests "int-${nsname}-${tgtname}-t1" "${nsname}" "${target_ip}" "1" "${len}"
	netperf_run_tests "int-${nsname}-${tgtname}-t${netperf_nr_threads}" "${nsname}" "${target_ip}" "${netperf_nr_threads}" "${len}"
}

netperf_run() {
	local nsname="ns${1}"
	local target_nsid="$2"
	local len=${NETPERF_TEST_LEN}

	netperf_run_veth ${nsname} ${target_nsid} ${len}
	netperf_run_int ${nsname} ${target_nsid} ${len}
}

netserver_kill() {
	local target_ip="$1"

	for pid in $(pidof netserver); do
		grep -q "${target_ip}" /proc/${pid}/cmdline && kill -9 ${pid};
	done
}

iptables_flush() {
	iptables -F
	iptables -F -t nat
}

openvswitch_deploy() {
	rpm -q --quiet openvswitch
	if [ $? -ne 0 ]; then
		yum install openvswitch -y
	fi

	systemctl start openvswitch
	for br in $(ovs-vsctl list-br); do
		ovs-vsctl del-br ${br}
	done

	systemctl stop openvswitch
	systemctl start openvswitch

	ovs-vsctl add-br ovsbr0

	echo "openvswitch is running"
}

openvswitch_set_flows() {
	local nsid1="$1"
	local nsid2="$2"

	ovs-ofctl del-flows ovsbr0
	ofport1=$(ovs-ofctl dump-ports-desc ovsbr0  | sed -n 's@ \+\([0-9]\+\)(int_ns1):.*@\1@p')
	ofport2=$(ovs-ofctl dump-ports-desc ovsbr0  | sed -n 's@ \+\([0-9]\+\)(int_ns2):.*@\1@p')
	ovs-ofctl add-flow ovsbr0 in_port=${ofport1},actions=output:${ofport2}
	ovs-ofctl add-flow ovsbr0 in_port=${ofport2},actions=output:${ofport1}

	ofport1=$(ovs-ofctl dump-ports-desc ovsbr0  | sed -n 's@ \+\([0-9]\+\)(veth_ovs_ns1):.*@\1@p')
	ofport2=$(ovs-ofctl dump-ports-desc ovsbr0  | sed -n 's@ \+\([0-9]\+\)(veth_ovs_ns2):.*@\1@p')
	ovs-ofctl add-flow ovsbr0 in_port=${ofport1},actions=output:${ofport2}
	ovs-ofctl add-flow ovsbr0 in_port=${ofport2},actions=output:${ofport1}
}

iface_set_noqueue() {
	local iface="$1"

	# Change to a none default qdisc (here one not depending on tx_queue_len)
	tc qdisc replace dev ${iface} root pfifo limit 42

	# Change tx_queue_len to zero
	ip link set ${iface} txqueuelen 0

	# Delete root qdisc, resulting in "noqueue" because txqueuelen was zero
	tc qdisc del dev ${iface} root

	# Verify the qdisc changed to "noqueue" listing with cmd:
	ip link show ${iface} | grep -q noop
	if [ $? -ne 0 ]; then
		echo "fail to set noqueue on ${iface}"
		exit -1
	fi
}

namespace_create() {
	local nsid="$1"
	local nsname="ns${nsid}"

	ip netns list | grep -q ${nsname}
	if [ $? -eq 0 ]; then
		# destroy the previous setup
		# the internal ports should be already flushed
		ip link del veth_ovs_${nsname}
		netserver_kill 10.100.0.${nsid}
		netserver_kill 10.200.0.${nsid}
		ip netns delete ${nsname}
		if [ $? -ne 0 ]; then
			# netns is busy, fail
			echo "fail to delete netns ${nsname}"
			exit 1
		fi
	fi

	ip netns add ${nsname}
	# lo
	ip netns exec ${nsname} ip link set lo up
	# veth
	ip link add name veth_ovs_${nsname} type veth peer name veth_${nsname}
	iface_set_noqueue veth_ovs_${nsname}
	iface_set_noqueue veth_${nsname}
	ip link set veth_${nsname} netns ${nsname}
	ip netns exec ${nsname} ip address add 10.100.0.${nsid}/24 dev veth_${nsname}
	ip netns exec ${nsname} ip link set veth_${nsname} up
	ip link set veth_ovs_${nsname} up
	ip netns exec ${nsname} netserver -L 10.100.0.${nsid}
	ovs-vsctl add-port ovsbr0 veth_ovs_${nsname}
	# internal
	ovs-vsctl add-port ovsbr0 int_${nsname} -- set Interface int_${nsname} type=internal
	ip link set int_${nsname} netns ${nsname}
	ip netns exec ${nsname} ip link set int_${nsname} up
	ip netns exec ${nsname} ip address add 10.200.0.${nsid}/24 dev int_${nsname}
	ip netns exec ${nsname} netserver -L 10.200.0.${nsid}
}

namespace_run() {
	local _logdir="log.$(date +'%Y%m%d%H%M%S')"

	if [ ! -d "${_logdir}" ]; then
		mkdir ${_logdir}
		if [ $? -ne 0 ]; then
			echo "fail to create logdir $(pwd)/${_logdir}"
			exit -1
		fi
	fi

	LOGDIR="${_logdir}"
	for i in $(seq 1 ${NETPERF_TEST_ROUNDS}); do
		netperf_run $1 $2
	done
}

irqbalance_off() {
	systemctl stop irqbalance
}


echo "1. setting performance"
cpu_get_cstates
cpu_set_gov performance
irqbalance_off
echo "2. checking for netperf"
netperf_deploy
netperf_init
echo "3. and now for openvswitch"
openvswitch_deploy
echo "4. setting up one netns"
namespace_create 1
echo "5. setting up the other netns"
namespace_create 2
echo "6. setting up flows"
openvswitch_set_flows 1 2
echo "7. cleaning iptables"
iptables_flush
echo "8. running netperf"
namespace_run 1 2
#namespace_run 2 1



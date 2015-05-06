The goal of this script is to measure the performance when
using Open vSwitch's internal ports and Linux veth devices
to connect network namespaces like conntainers do. For that,
it will create a pair of namespaces and establish a network
between them using Open vSwitch bridge and then execute some
netperf tests in the testing environment.

Of course, measuring performance is a complex task and this
script does some work to compare apples to apples and also
to get more stable numbers, but still it's far from being
complete.  It's also limited to netperf tests which is just
one artificial way of measure throughput and latency.

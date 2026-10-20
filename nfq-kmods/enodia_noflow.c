// SPDX-License-Identifier: MIT
/* A no-op conntrack helper for flows that must stay on the kernel's software path.
 * QSDK ECM refuses acceleration when a conntrack helper is attached. Assign this helper
 * explicitly with CT --helper enodia_noflow in raw PREROUTING, BEFORE a connection exists.
 * It never changes packets, NAT, marks or expectations. Port zero prevents automatic assignment
 * to ordinary services; only the narrowly scoped CT rule opts a flow in.
 */
#include <linux/module.h>
#include <linux/netfilter.h>
#include <net/netfilter/nf_conntrack_helper.h>

/* Read-only, opt-in counters let the hardware test prove real helper calls without per-packet logging. */
static bool stats;
module_param(stats, bool, 0444);
static atomic64_t noflow_packets = ATOMIC64_INIT(0);

static int counter_get(char *buffer, const struct kernel_param *kp)
{
    return scnprintf(buffer, PAGE_SIZE, "%llu\n", (unsigned long long)atomic64_read((atomic64_t *)kp->arg));
}
static const struct kernel_param_ops counter_ops = { .get = counter_get };
module_param_cb(packets, &counter_ops, &noflow_packets, 0444);

static int noflow_help(struct sk_buff *skb, unsigned int protoff,
                      struct nf_conn *ct, enum ip_conntrack_info ctinfo)
{
    /* Do not inspect conntrack private data or callback arguments: the stock's internal ABI is not proven.
     * An instrumented variant that wrote a per-flow bit through nfct_help_data rebooted the test router.
     */
    if (stats)
        atomic64_inc(&noflow_packets);
    return NF_ACCEPT;
}

static const struct nf_conntrack_expect_policy noflow_policy = {
    .max_expected = 0,
    .timeout = 1,
};

#define NOFLOW_HELPER(proto) { \
    .name = "enodia_noflow", \
    .me = THIS_MODULE, \
    .expect_policy = &noflow_policy, \
    .tuple.src.l3num = AF_INET, \
    .tuple.dst.protonum = proto, \
    .help = noflow_help, \
}

static struct nf_conntrack_helper noflow_helpers[] = {
    NOFLOW_HELPER(IPPROTO_TCP),
    NOFLOW_HELPER(IPPROTO_UDP),
};

static int __init noflow_init(void)
{
    int i, ret;
    for (i = 0; i < ARRAY_SIZE(noflow_helpers); i++) {
        ret = nf_conntrack_helper_register(&noflow_helpers[i]);
        if (ret) {
            while (i--)
                nf_conntrack_helper_unregister(&noflow_helpers[i]);
            return ret;
        }
    }
    return 0;
}

static void __exit noflow_exit(void)
{
    int i;
    for (i = ARRAY_SIZE(noflow_helpers); i-- > 0;)
        nf_conntrack_helper_unregister(&noflow_helpers[i]);
}

module_init(noflow_init);
module_exit(noflow_exit);
MODULE_LICENSE("Dual MIT/GPL");
MODULE_DESCRIPTION("Explicit conntrack helper to keep selected flows out of ECM acceleration");

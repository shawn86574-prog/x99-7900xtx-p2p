// 绕过 X99/Broadwell-EP 的 pci_p2pdma 芯片组白名单：
// amdgpu 只通过 pci_p2pdma_distance_many() 的返回值判断对端可不可达，
// 这里用 kretprobe 把该调用强制返回正值（距离=1），思路同 lcz.me #2599 的 amdgpu_p2p_force。
// 只影响调用该符号的驱动（本机即 amdgpu），不改内核、不改 amdgpu.ko。
//
// 加固：只对"provider 是 AMD 显卡"的查询篡改返回值，其余一律放行真实结果。
// 该符号在内核树里还有 xe / habanalabs / nvmet 三个导入者，且机器上还有一张
// NVIDIA 亮机卡；不设条件的话，非 P2P 设备会被当成可达对端（DMA 到非法 BAR）。
// 结构体偏移按当前内核头文件编译，因此模块必须随内核重编（DKMS）。
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/kprobes.h>
#include <linux/ptrace.h>
#include <linux/pci.h>
#include <linux/pci_ids.h>

static atomic_t forced_count = ATOMIC_INIT(0);
static atomic_t skipped_count = ATOMIC_INIT(0);

static int entry_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	struct pci_dev *provider = (struct pci_dev *)regs_get_kernel_argument(regs, 0);
	int *flag = (int *)ri->data;

	/* provider 是本次查询的对端设备；只有 AMD 显卡才值得伪造可达性 */
	*flag = (provider && provider->vendor == PCI_VENDOR_ID_ATI) ? 1 : 0;
	return 0;
}

static int ret_handler(struct kretprobe_instance *ri, struct pt_regs *regs)
{
	int flag = *(int *)ri->data;

	if (flag) {
		regs_set_return_value(regs, 1);
		atomic_inc(&forced_count);
	} else {
		atomic_inc(&skipped_count);
	}
	return 0;
}

static struct kretprobe p2p_krp = {
	.kp.symbol_name = "pci_p2pdma_distance_many",
	.entry_handler = entry_handler,
	.handler = ret_handler,
	.maxactive = 32,
	.data_size = sizeof(int),
};

static int __init p2p_force_init(void)
{
	int ret = register_kretprobe(&p2p_krp);

	if (ret)
		pr_err("p2p_force: register_kretprobe failed %d\n", ret);
	else
		pr_info("p2p_force: 已在 pci_p2pdma_distance_many 上挂钩（仅对 AMD 对端生效）\n");
	return ret;
}

static void __exit p2p_force_exit(void)
{
	unregister_kretprobe(&p2p_krp);
	pr_info("p2p_force: 已卸载，强制 %d 次，放行 %d 次\n",
		atomic_read(&forced_count), atomic_read(&skipped_count));
}

module_init(p2p_force_init);
module_exit(p2p_force_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Force pci_p2pdma_distance_many to report peer distance (X99 P2P, AMD provider only)");

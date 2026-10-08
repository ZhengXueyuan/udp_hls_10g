// ===========================================================================
// p7b_spsc.h -- 无锁 **有界** SPSC 环形队列 (P7b 台架双线程样板, 2026-10-09)
//
// 为什么 (用户 2026-10-09 逐字要求): "将发送/接收放在一个单独的线程中, 另一个线程负责
//   产生或者消费数据, 两个线程之间用无锁队列通信。这样发送和接收数据可以达到最快。"
//
// 合同 (读之前先读这条, 它是本文件唯一的正确性来源):
//   * **单生产者单消费者** (SPSC) —— 队列**任意时刻只许一条线程 push、另一条线程 pop**。
//     因此**不需要 CAS**, head/tail 各由一个线程写。
//   * **有界** —— 容量在构造时定死 (向上取整到 2 的幂)。满了 push 返回 false (不覆盖、
//     不阻塞、**绝不扩容**)。⛔ 不用无界队列: 无界队列 = 把内存当队列 = 另一条 IO 瓶颈
//     (与用户要求的"最快"直接冲突), 而且会把背压变成 OOM。
//   * 同步**全部**是 std::atomic 的 acquire/release; ⛔ **不用 std::mutex / 不用条件变量**
//     (锁会引入内核参与与优先级反转, 正是"无锁队列"要避开的东西)。
//   * 伪共享: head 与 tail 各自 alignas(64) 独占一条 cache line; 两侧的统计计数分别**跟在
//     自己那一侧的行内** (各自只被一条线程写 ⇒ 普通整数即可, 不必原子)。
//   * ⛔ 不做内存回收: 元素在 push 当拍被**拷贝入环**; pop 出来的是副本。要传大块数据时,
//     元素里放**指针/槽号** (本工程的用法: 槽池 + 槽号), 避免拷贝。
//
// 用法 (本工程): full = I/O 线程 → 校验线程; free = 校验线程 → I/O 线程 (还槽)。
//
// 见证 (调用方各自打印, 本头只提供读数): pushed/popped/push_failed/pop_failed。
//   ⚠️ pop_failed 包含"消费者主动轮询到空"的次数 ⇒ 它**不是**错误计数, 只是形态量;
//      判"队列不丢不漏"用的是 **pushed == popped** (两端各自只加一次)。
// ===========================================================================
#ifndef P7B_SPSC_H
#define P7B_SPSC_H

#include <atomic>
#include <cstddef>
#include <memory>

template <typename T>
class P7bSpscRing {
public:
    // cap_hint 会被向上取整到 2 的幂 (最小 2)
    explicit P7bSpscRing(size_t cap_hint = 16) {
        size_t c = 2;
        while (c < cap_hint) c <<= 1;
        cap_ = c;
        mask_ = c - 1;
        buf_.reset(new T[c]);
    }

    // ---------------------- 生产者侧 (只许一条线程调) ----------------------
    bool push(const T &v) {
        const size_t head = head_.load(std::memory_order_relaxed);
        const size_t tail = tail_.load(std::memory_order_acquire);
        if (head - tail >= cap_) { prod_.push_fail++; return false; }
        buf_[head & mask_] = v;
        head_.store(head + 1, std::memory_order_release);   // 提交: 元素先写, 指针后放
        prod_.pushed++;
        return true;
    }

    // ---------------------- 消费者侧 (只许**另一条**线程调) ----------------------
    bool pop(T &v) {
        const size_t tail = tail_.load(std::memory_order_relaxed);
        const size_t head = head_.load(std::memory_order_acquire);
        if (tail == head) { cons_.pop_fail++; return false; }
        v = buf_[tail & mask_];
        tail_.store(tail + 1, std::memory_order_release);
        cons_.popped++;
        return true;
    }

    // ---------------------- 只读 (任一侧; 不保证瞬时一致) ----------------------
    size_t capacity() const { return cap_; }
    size_t size() const {
        return head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_acquire);
    }
    unsigned long long pushed() const { return prod_.pushed; }
    unsigned long long popped() const { return cons_.popped; }
    unsigned long long push_failed() const { return prod_.push_fail; }
    unsigned long long pop_failed() const { return cons_.pop_fail; }

private:
    struct ProdStats { unsigned long long pushed = 0; unsigned long long push_fail = 0; };
    struct ConsStats { unsigned long long popped = 0; unsigned long long pop_fail = 0; };

    std::unique_ptr<T[]> buf_;
    size_t cap_ = 0, mask_ = 0;

    alignas(64) std::atomic<size_t> head_{0};   // 生产者写, 消费者读
    alignas(64) ProdStats prod_;                // 只被生产者写

    alignas(64) std::atomic<size_t> tail_{0};   // 消费者写, 生产者读
    alignas(64) ConsStats cons_;                // 只被消费者写

    P7bSpscRing(const P7bSpscRing &) = delete;
    P7bSpscRing &operator=(const P7bSpscRing &) = delete;
};

#endif  // P7B_SPSC_H

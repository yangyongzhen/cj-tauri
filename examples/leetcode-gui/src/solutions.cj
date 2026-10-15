package leetcode_gui

/**
 * 参考答案（每题一份可直接编译通过的仓颉实现）
 *
 * 存储形式：raw 字符串 #\#" ... "#（不是普通三引号字符串）——raw 字符串不做转义处理，
 * 代码里的引号、反斜杠都原样保留，避开 AGENTS §4 的三引号转义坑；代码内部不得出现
 * 收尾序列（引号+#）。
 *
 * 使用方式：leetcode:solution 命令按题号取答案交给前端（用户选择「载入答案」才覆盖编辑器，
 * 并在终端标注「来自参考答案」）。每份答案都经过与判题同款的「答案 + harness」cjc 编译
 * 与逐用例运行验证（scripts 侧批量自检，见 README §6）。
 *
 * 参考答案是「做不出来再看」的工具：前端载入前会先确认，避免误触剧透。
 */

/** 按题号取参考答案；没有答案的题返回空串（前端提示无答案） */
func solutionFor(id: Int64): String {
    match (id) {
        case 1 => return #"func twoSum(nums: Array<Int64>, target: Int64): Array<Int64> {
    let seen = HashMap<Int64, Int64>()
    for (i in 0..nums.size) {
        let need = target - nums[i]
        match (seen.get(need)) {
            case Some(j) => return [j, i]
            case None => ()
        }
        seen.add(nums[i], i)
    }
    return []
}"#
        case 2 => return #"func majorityElement(nums: Array<Int64>): Int64 {
    // 摩尔投票：不同的互相抵消，剩下来的就是多数
    var cand: Int64 = 0
    var count: Int64 = 0
    for (x in nums) {
        if (count == 0) {
            cand = x
            count = 1
        } else if (x == cand) {
            count = count + 1
        } else {
            count = count - 1
        }
    }
    return cand
}"#
        case 3 => return #"func moveZeroes(nums: Array<Int64>): Array<Int64> {
    // 快慢指针：慢指针指向下一个非零元素该放的位置
    var slow: Int64 = 0
    for (fast in 0..nums.size) {
        if (nums[fast] != 0) {
            let tmp = nums[slow]
            nums[slow] = nums[fast]
            nums[fast] = tmp
            slow = slow + 1
        }
    }
    return nums
}"#
        case 4 => return #"func maxArea(height: Array<Int64>): Int64 {
    // 左右指针向中间收：每次移动较短的一侧（移动长的一侧只会更差）
    var left: Int64 = 0
    var right: Int64 = height.size - 1
    var best: Int64 = 0
    while (left < right) {
        var h = height[left]
        if (height[right] < h) {
            h = height[right]
        }
        let area = h * (right - left)
        if (area > best) {
            best = area
        }
        if (height[left] < height[right]) {
            left = left + 1
        } else {
            right = right - 1
        }
    }
    return best
}"#
        case 5 => return #"func mergeSorted(nums1: Array<Int64>, nums2: Array<Int64>): Array<Int64> {
    // 归并：双指针各走各的，小的先进
    let out = ArrayList<Int64>()
    var i: Int64 = 0
    var j: Int64 = 0
    while (i < nums1.size && j < nums2.size) {
        if (nums1[i] <= nums2[j]) {
            out.add(nums1[i])
            i = i + 1
        } else {
            out.add(nums2[j])
            j = j + 1
        }
    }
    while (i < nums1.size) {
        out.add(nums1[i])
        i = i + 1
    }
    while (j < nums2.size) {
        out.add(nums2[j])
        j = j + 1
    }
    return out.toArray()
}"#
        case 6 => return #"func reverseString(s: String): String {
    // 按字节收集再倒拼（本题素材是 ASCII，字节序 == 字符序）
    let bytes = s.toArray()
    let out = ArrayList<UInt8>()
    var i = bytes.size - 1
    while (i >= 0) {
        out.add(bytes[i])
        i = i - 1
    }
    return String.fromUtf8(out.toArray())
}"#
        case 7 => return #"func longestCommonPrefix(strs: Array<String>): String {
    if (strs.size == 0) {
        return ""
    }
    // 以第一个串为基准，逐个字符与其余串对齐
    let first = strs[0].toArray()
    var keep: Int64 = 0
    for (k in 0..first.size) {
        let c = first[k]
        for (t in 1..strs.size) {
            let other = strs[t].toArray()
            if (k >= other.size || other[k] != c) {
                return String.fromUtf8(first[0..keep].toArray())
            }
        }
        keep = keep + 1
    }
    return String.fromUtf8(first[0..keep].toArray())
}"#
        case 8 => return #"func isPalindrome(s: String): Bool {
    // 双指针从两端向中间收，逐字节比较（本题只考虑小写字母）
    let bytes = s.toArray()
    var left: Int64 = 0
    var right = bytes.size - 1
    while (left < right) {
        if (bytes[left] != bytes[right]) {
            return false
        }
        left = left + 1
        right = right - 1
    }
    return true
}"#
        case 9 => return #"func isValid(s: String): Bool {
    // 栈：左括号压栈，右括号弹栈配对
    let bytes = s.toArray()
    let stack = ArrayList<UInt8>()
    for (c in bytes) {
        if (c == 40 || c == 91 || c == 123) {
            stack.add(c)
        } else {
            if (stack.size == 0) {
                return false
            }
            let top = stack[stack.size - 1]
            // 40=() 91=[] 123={}：右括号要与栈顶同型
            let ok = (c == 41 && top == 40) || (c == 93 && top == 91) || (c == 125 && top == 123)
            if (!ok) {
                return false
            }
            stack.remove(at: stack.size - 1)
        }
    }
    return stack.size == 0
}"#
        case 10 => return #"func minStackFinal(ops: Array<Int64>): Int64 {
    // 主栈 + 辅助栈（每压一个数，辅助栈同步压「当前最小」）
    let stack = ArrayList<Int64>()
    let mins = ArrayList<Int64>()
    var last = 0
    for (op in ops) {
        if (op == -2) {
            if (mins.size > 0) {
                last = mins[mins.size - 1]
            }
        } else if (op == -1) {
            if (stack.size > 0) {
                stack.remove(at: stack.size - 1)
                mins.remove(at: mins.size - 1)
            }
        } else {
            stack.add(op)
            var m = op
            if (mins.size > 0 && mins[mins.size - 1] < m) {
                m = mins[mins.size - 1]
            }
            mins.add(m)
        }
    }
    return last
}"#
        case 11 => return #"func search(nums: Array<Int64>, target: Int64): Int64 {
    var lo: Int64 = 0
    var hi = nums.size - 1
    while (lo <= hi) {
        let mid = (lo + hi) / 2
        if (nums[mid] == target) {
            return mid
        } else if (nums[mid] < target) {
            lo = mid + 1
        } else {
            hi = mid - 1
        }
    }
    return -1
}"#
        case 12 => return #"func searchInsert(nums: Array<Int64>, target: Int64): Int64 {
    // 二分找第一个 >= target 的位置
    var lo: Int64 = 0
    var hi = nums.size
    while (lo < hi) {
        let mid = (lo + hi) / 2
        if (nums[mid] < target) {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo
}"#
        case 13 => return #"func climbStairs(n: Int64): Int64 {
    // 滚动变量：f(i) = f(i-1) + f(i-2)
    if (n <= 2) {
        return n
    }
    var prev: Int64 = 1
    var cur: Int64 = 2
    for (i in 3..n + 1) {
        let next = prev + cur
        prev = cur
        cur = next
    }
    return cur
}"#
        case 14 => return #"func rob(nums: Array<Int64>): Int64 {
    // 打家劫舍：dp[i] = max(dp[i-1], dp[i-2] + nums[i])，滚动变量版
    var prev: Int64 = 0
    var cur: Int64 = 0
    for (x in nums) {
        let next = if (cur > prev + x) { cur } else { prev + x }
        prev = cur
        cur = next
    }
    return cur
}"#
        case 15 => return #"func maxSubArray(nums: Array<Int64>): Int64 {
    // Kadane：前缀和一路走，跌破 0 就重新起头
    var best = nums[0]
    var here: Int64 = 0
    for (x in nums) {
        if (here < 0) {
            here = x
        } else {
            here = here + x
        }
        if (here > best) {
            best = here
        }
    }
    return best
}"#
        case 16 => return #"func maxProfit(prices: Array<Int64>): Int64 {
    // 记录历史最低价，每天算「今天卖」的最大利润
    var lowest = prices[0]
    var best: Int64 = 0
    for (p in prices) {
        if (p < lowest) {
            lowest = p
        } else if (p - lowest > best) {
            best = p - lowest
        }
    }
    return best
}"#
        case 17 => return #"func findContentChildren(g: Array<Int64>, s: Array<Int64>): Int64 {
    // 两个数组都升序排好后双指针：最小的饼干喂给胃口最小且能饱的孩子
    let kids = ArrayList<Int64>()
    for (x in g) { kids.add(x) }
    let cookies = ArrayList<Int64>()
    for (x in s) { cookies.add(x) }
    sortAsc(kids)
    sortAsc(cookies)
    var i: Int64 = 0
    var j: Int64 = 0
    var fed: Int64 = 0
    while (i < kids.size && j < cookies.size) {
        if (cookies[j] >= kids[i]) {
            fed = fed + 1
            i = i + 1
        }
        j = j + 1
    }
    return fed
}

/** 升序插入排序（数组规模小，简单可靠优先） */
func sortAsc(a: ArrayList<Int64>): Unit {
    for (i in 1..a.size) {
        var j = i
        while (j > 0 && a[j - 1] > a[j]) {
            let tmp = a[j - 1]
            a[j - 1] = a[j]
            a[j] = tmp
            j = j - 1
        }
    }
}"#
        case 18 => return #"func singleNumber(nums: Array<Int64>): Int64 {
    // 异或：相同的抵消成 0，剩下那个就是答案
    var acc: Int64 = 0
    for (x in nums) {
        acc = acc ^ x
    }
    return acc
}"#
        case 19 => return #"func countPrimes(n: Int64): Int64 {
    // 埃氏筛：从 2 起，把每个质数的倍数划掉
    if (n <= 2) {
        return 0
    }
    let composite = Array<Bool>(n, repeat: false)
    var count: Int64 = 0
    for (i in 2..n) {
        if (!composite[i]) {
            count = count + 1
            var j = i * i
            while (j < n) {
                composite[j] = true
                j = j + i
            }
        }
    }
    return count
}"#
        // ---- 以下为远程题包 advanced-1 的 8 题（id 100+，答案与题包同仓维护）----
        case 100 => return #"func fib(n: Int64): Int64 {
    // 滚动变量：递归是 O(2^n)，这里 O(n)
    if (n <= 1) {
        return n
    }
    var prev: Int64 = 0
    var cur: Int64 = 1
    for (i in 2..n + 1) {
        let next = prev + cur
        prev = cur
        cur = next
    }
    return cur
}"#
        case 101 => return #"func permuteCount(nums: Array<Int64>): Int64 {
    // 回溯生成全排列并计数：used[i] 标记已用元素
    let used = Array<Bool>(nums.size, repeat: false)
    let cur = ArrayList<Int64>()
    return backtrack(nums, used, cur)
}

// 返回从当前前缀出发能生成的完整排列数
func backtrack(nums: Array<Int64>, used: Array<Bool>, cur: ArrayList<Int64>): Int64 {
    if (cur.size == nums.size) {
        return 1
    }
    var total: Int64 = 0
    for (i in 0..nums.size) {
        if (!used[i]) {
            used[i] = true
            cur.add(nums[i])
            total = total + backtrack(nums, used, cur)
            cur.remove(at: cur.size - 1)
            used[i] = false
        }
    }
    return total
}"#
        case 102 => return #"func generateParenthesis(n: Int64): Int64 {
    // 回溯：任意前缀里左括号数 >= 右括号数，且都不超 n
    return gen(n, 0, 0)
}

// 返回从 (open, close) 状态出发能生成的合法组合数
func gen(n: Int64, open: Int64, close: Int64): Int64 {
    if (open == n && close == n) {
        return 1
    }
    var total: Int64 = 0
    if (open < n) {
        total = total + gen(n, open + 1, close)
    }
    if (close < open) {
        total = total + gen(n, open, close + 1)
    }
    return total
}"#
        case 103 => return #"func numIslands(grid: Array<String>): Int64 {
    // FloodFill：遇到 '1' 计一座岛，并把整片陆地感染成 '0'
    let g = ArrayList<String>()
    for (row in grid) { g.add(row) }
    var count: Int64 = 0
    for (r in 0..g.size) {
        for (c in 0..g[r].size) {
            // 每一步都重读当前行：sink 会改写 g[r]，缓存的字节副本会过期，
            // 把已沉没的陆地再当新岛数一遍（实测重复计数）
            let row = g[r].toArray()
            if (row[c] == 49) {
                count = count + 1
                sink(g, r, c)
            }
        }
    }
    return count
}

// 把 (r,c) 连通的陆地全部染成水
func sink(g: ArrayList<String>, r: Int64, c: Int64): Unit {
    if (r < 0 || r >= g.size || c < 0 || c >= g[r].size) {
        return
    }
    let row = g[r].toArray()
    if (row[c] != 49) {
        return
    }
    row[c] = 48
    g[r] = String.fromUtf8(row.toArray())
    sink(g, r - 1, c)
    sink(g, r + 1, c)
    sink(g, r, c - 1)
    sink(g, r, c + 1)
}"#
        case 104 => return #"func combinationSumCount(candidates: Array<Int64>, target: Int64): Int64 {
    // 回溯：元素可重复选，为避免重复组合只从「当前下标起」往后取
    return combo(candidates, 0, target)
}

// 返回从 (start, remain) 状态出发能凑出 target 的组合数
func combo(candidates: Array<Int64>, start: Int64, remain: Int64): Int64 {
    if (remain == 0) {
        return 1
    }
    if (remain < 0) {
        return 0
    }
    var total: Int64 = 0
    for (i in start..candidates.size) {
        total = total + combo(candidates, i, remain - candidates[i])
    }
    return total
}"#
        case 105 => return #"func findKthLargest(nums: Array<Int64>, k: Int64): Int64 {
    // 快速选择：平均 O(n)
    let a = ArrayList<Int64>()
    for (x in nums) { a.add(x) }
    return quickSelect(a, 0, a.size - 1, a.size - k)
}

func quickSelect(a: ArrayList<Int64>, lo: Int64, hi: Int64, target: Int64): Int64 {
    if (lo == hi) {
        return a[lo]
    }
    // 以 a[hi] 为 pivot 分区
    var store = lo
    var i = lo
    while (i < hi) {
        if (a[i] < a[hi]) {
            let t = a[store]
            a[store] = a[i]
            a[i] = t
            store = store + 1
        }
        i = i + 1
    }
    let t = a[store]
    a[store] = a[hi]
    a[hi] = t
    if (store == target) {
        return a[store]
    } else if (store < target) {
        return quickSelect(a, store + 1, hi, target)
    } else {
        return quickSelect(a, lo, store - 1, target)
    }
}"#
        case 106 => return #"func topKFrequent(nums: Array<Int64>, k: Int64): Int64 {
    // 计数 → 按次数降序取前 k → 求和
    let counts = HashMap<Int64, Int64>()
    for (x in nums) {
        match (counts.get(x)) {
            case Some(c) => counts.add(x, c + 1)
            case None => counts.add(x, 1)
        }
    }
    let freqs = ArrayList<Int64>()
    for ((_, c) in counts) {
        freqs.add(c)
    }
    sortByDesc(freqs)
    var sum: Int64 = 0
    for (i in 0..k) {
        sum = sum + freqs[i]
    }
    return sum
}

func sortByDesc(a: ArrayList<Int64>): Unit {
    for (i in 1..a.size) {
        var j = i
        while (j > 0 && a[j - 1] < a[j]) {
            let t = a[j - 1]
            a[j - 1] = a[j]
            a[j] = t
            j = j - 1
        }
    }
}"#
        case 107 => return #"func canFinish(numCourses: Int64, prerequisites: Array<Int64>): Bool {
    // 拓扑排序（Kahn）：反复摘掉入度为 0 的点，摘得完就无环
    let indegree = Array<Int64>(numCourses, repeat: 0)
    let adj = ArrayList<ArrayList<Int64>>()
    for (i in 0..numCourses) { adj.add(ArrayList<Int64>()) }
    var i: Int64 = 0
    while (i + 1 < prerequisites.size) {
        let a = prerequisites[i]
        let b = prerequisites[i + 1]
        adj[b].add(a)
        indegree[a] = indegree[a] + 1
        i = i + 2
    }
    let queue = ArrayList<Int64>()
    for (c in 0..numCourses) {
        if (indegree[c] == 0) {
            queue.add(c)
        }
    }
    var done: Int64 = 0
    var head: Int64 = 0
    while (head < queue.size) {
        let cur = queue[head]
        head = head + 1
        done = done + 1
        for (next in adj[cur]) {
            indegree[next] = indegree[next] - 1
            if (indegree[next] == 0) {
                queue.add(next)
            }
        }
    }
    return done == numCourses
}"#
        case _ => return ""
    }
}

package leetcode_gui

/**
 * 仓颉版力扣·题库数据（内嵌 JSON）
 *
 * 每条题目：
 *   id / title / difficulty / category   题号、标题、难度、分类（前端按 category 分组）
 *   funcName                  用户要实现的仓颉函数名
 *   description               题目描述（JSON 里的 \n 转成换行）
 *   template                  编辑器初始代码（仓颉函数 + TODO 占位）
 *   tests                     测试用例：call 是完整调用表达式，expect 是期望结果的仓颉字面量
 *
 * 转义铁律（AGENTS §4）：本文件是仓颉三引号字符串——
 *   · JSON 的 \n 必须写成 \\n（否则被吃成真换行，JSON 当场非标准）；
 *   · 用例里字符串字面量的引号必须写成 \\\"（否则提前终止 JSON 字符串）。
 *   · 题面 / 模板 / 答案里都不能出现 ${…}——三引号里的插值是**活的**，${x} 会被当成变量引用，
 *     应用一编译就报 undeclared identifier（答案要拼字符串就写 x.toString()）。
 * 改完用 build 前先跑 scripts 侧的 JSON 自检（main.cj 启动即校验，解析失败会在 stderr 喊）。
 *
 * 全部数据来自公开算法题的通用描述，不含任何受版权保护的题解。
 */
let LC_PROBLEMS_JSON: String = """
{
  "problems": [
    {
      "id": 1,
      "title": "两数之和",
      "difficulty": "简单",
      "category": "哈希与计数",
      "funcName": "twoSum",
      "description": "给定一个整数数组 nums 和一个整数目标值 target，请你在该数组中找出和为目标值 target 的那两个整数，并返回它们的数组下标。\n你可以假设每种输入只会对应一个答案；数组中同一个元素在答案里不能重复出现。",
      "template": "func twoSum(nums: Array<Int64>, target: Int64): Array<Int64> {\n    // 请在这里实现算法（提示：哈希表）\n    return []\n}",
      "tests": [
        {"call": "twoSum([2, 7, 11, 15], 9)", "expect": "[0, 1]"},
        {"call": "twoSum([3, 2, 4], 6)", "expect": "[1, 2]"},
        {"call": "twoSum([3, 3], 6)", "expect": "[0, 1]"}
      ],
      "solution": "func twoSum(nums: Array<Int64>, target: Int64): Array<Int64> {\\n    let seen = HashMap<Int64, Int64>()\\n    for (i in 0..nums.size) {\\n        let need = target - nums[i]\\n        match (seen.get(need)) {\\n            case Some(j) => return [j, i]\\n            case None => ()\\n        }\\n        seen.add(nums[i], i)\\n    }\\n    return []\\n}"
    },
    {
      "id": 2,
      "title": "多数元素",
      "difficulty": "简单",
      "category": "哈希与计数",
      "funcName": "majorityElement",
      "description": "给定一个大小为 n 的数组 nums，返回其中的多数元素。多数元素是指在数组中出现次数大于 n/2 的元素。\n你可以假设数组是非空的，并且给定的数组总是存在多数元素。\n进阶：尝试使用 O(1) 空间解法（摩尔投票）。",
      "template": "func majorityElement(nums: Array<Int64>): Int64 {\n    // 请在这里实现算法（提示：摩尔投票）\n    return 0\n}",
      "tests": [
        {"call": "majorityElement([3, 2, 3])", "expect": "3"},
        {"call": "majorityElement([2, 2, 1, 1, 1, 2, 2])", "expect": "2"},
        {"call": "majorityElement([6, 5, 5])", "expect": "5"}
      ],
      "solution": "func majorityElement(nums: Array<Int64>): Int64 {\\n    // 摩尔投票：不同的互相抵消，剩下来的就是多数\\n    var cand: Int64 = 0\\n    var count: Int64 = 0\\n    for (x in nums) {\\n        if (count == 0) {\\n            cand = x\\n            count = 1\\n        } else if (x == cand) {\\n            count = count + 1\\n        } else {\\n            count = count - 1\\n        }\\n    }\\n    return cand\\n}"
    },
    {
      "id": 3,
      "title": "移动零",
      "difficulty": "简单",
      "category": "数组与双指针",
      "funcName": "moveZeroes",
      "description": "给定一个数组 nums，编写一个函数将所有 0 移动到数组的末尾，同时保持非零元素的相对顺序。\n要求：必须在不复制数组的情况下原地对数组进行操作（返回操作后的数组即可）。",
      "template": "func moveZeroes(nums: Array<Int64>): Array<Int64> {\n    // 请在这里实现算法（提示：快慢指针）\n    return nums\n}",
      "tests": [
        {"call": "moveZeroes([0, 1, 0, 3, 12])", "expect": "[1, 3, 12, 0, 0]"},
        {"call": "moveZeroes([0])", "expect": "[0]"},
        {"call": "moveZeroes([1, 2])", "expect": "[1, 2]"}
      ],
      "solution": "func moveZeroes(nums: Array<Int64>): Array<Int64> {\\n    // 快慢指针：慢指针指向下一个非零元素该放的位置\\n    var slow: Int64 = 0\\n    for (fast in 0..nums.size) {\\n        if (nums[fast] != 0) {\\n            let tmp = nums[slow]\\n            nums[slow] = nums[fast]\\n            nums[fast] = tmp\\n            slow = slow + 1\\n        }\\n    }\\n    return nums\\n}"
    },
    {
      "id": 4,
      "title": "盛最多水的容器",
      "difficulty": "中等",
      "category": "数组与双指针",
      "funcName": "maxArea",
      "description": "给定一个长度为 n 的整数数组 height。有 n 条垂线，第 i 条线的两个端点是 (i, 0) 和 (i, height[i])。\n找出其中的两条线，使得它们与 x 轴共同构成的容器可以容纳最多的水。返回容器可以储存的最大水量。",
      "template": "func maxArea(height: Array<Int64>): Int64 {\n    // 请在这里实现算法（提示：左右指针向中间收）\n    return 0\n}",
      "tests": [
        {"call": "maxArea([1, 8, 6, 2, 5, 4, 8, 3, 7])", "expect": "49"},
        {"call": "maxArea([1, 1])", "expect": "1"},
        {"call": "maxArea([4, 3, 2, 1, 4])", "expect": "16"}
      ],
      "solution": "func maxArea(height: Array<Int64>): Int64 {\\n    // 左右指针向中间收：每次移动较短的一侧（移动长的一侧只会更差）\\n    var left: Int64 = 0\\n    var right: Int64 = height.size - 1\\n    var best: Int64 = 0\\n    while (left < right) {\\n        var h = height[left]\\n        if (height[right] < h) {\\n            h = height[right]\\n        }\\n        let area = h * (right - left)\\n        if (area > best) {\\n            best = area\\n        }\\n        if (height[left] < height[right]) {\\n            left = left + 1\\n        } else {\\n            right = right - 1\\n        }\\n    }\\n    return best\\n}"
    },
    {
      "id": 5,
      "title": "合并两个有序数组",
      "difficulty": "简单",
      "category": "数组与双指针",
      "funcName": "mergeSorted",
      "description": "给你两个按非递减顺序排列的整数数组 nums1 和 nums2，请你将它们合并成一个按非递减顺序排列的新数组并返回。",
      "template": "func mergeSorted(nums1: Array<Int64>, nums2: Array<Int64>): Array<Int64> {\n    // 请在这里实现算法（提示：双指针归并）\n    return []\n}",
      "tests": [
        {"call": "mergeSorted([1, 2, 3], [2, 5, 6])", "expect": "[1, 2, 2, 3, 5, 6]"},
        {"call": "mergeSorted([1], [])", "expect": "[1]"},
        {"call": "mergeSorted([], [0])", "expect": "[0]"}
      ],
      "solution": "func mergeSorted(nums1: Array<Int64>, nums2: Array<Int64>): Array<Int64> {\\n    // 归并：双指针各走各的，小的先进\\n    let out = ArrayList<Int64>()\\n    var i: Int64 = 0\\n    var j: Int64 = 0\\n    while (i < nums1.size && j < nums2.size) {\\n        if (nums1[i] <= nums2[j]) {\\n            out.add(nums1[i])\\n            i = i + 1\\n        } else {\\n            out.add(nums2[j])\\n            j = j + 1\\n        }\\n    }\\n    while (i < nums1.size) {\\n        out.add(nums1[i])\\n        i = i + 1\\n    }\\n    while (j < nums2.size) {\\n        out.add(nums2[j])\\n        j = j + 1\\n    }\\n    return out.toArray()\\n}"
    },
    {
      "id": 6,
      "title": "反转字符串",
      "difficulty": "简单",
      "category": "字符串",
      "funcName": "reverseString",
      "description": "编写一个函数，将输入的字符串反转过来并返回。输入字符串以字符数组为基础（本题为简单起见直接传 String，返回反转后的 String）。",
      "template": "func reverseString(s: String): String {\n    // 请在这里实现算法\n    return s\n}",
      "tests": [
        {"call": "reverseString(\\\"hello\\\")", "expect": "\\\"olleh\\\""},
        {"call": "reverseString(\\\"a\\\")", "expect": "\\\"a\\\""},
        {"call": "reverseString(\\\"\\\")", "expect": "\\\"\\\""}
      ],
      "solution": "func reverseString(s: String): String {\\n    // 按字节收集再倒拼（本题素材是 ASCII，字节序 == 字符序）\\n    let bytes = s.toArray()\\n    let out = ArrayList<UInt8>()\\n    var i = bytes.size - 1\\n    while (i >= 0) {\\n        out.add(bytes[i])\\n        i = i - 1\\n    }\\n    return String.fromUtf8(out.toArray())\\n}"
    },
    {
      "id": 7,
      "title": "最长公共前缀",
      "difficulty": "简单",
      "category": "字符串",
      "funcName": "longestCommonPrefix",
      "description": "编写一个函数来查找字符串数组中的最长公共前缀。如果不存在公共前缀，返回空字符串。",
      "template": "func longestCommonPrefix(strs: Array<String>): String {\n    // 请在这里实现算法\n    return \\\"\\\"\n}",
      "tests": [
        {"call": "longestCommonPrefix([\\\"flower\\\", \\\"flow\\\", \\\"flight\\\"])", "expect": "\\\"fl\\\""},
        {"call": "longestCommonPrefix([\\\"dog\\\", \\\"racecar\\\", \\\"car\\\"])", "expect": "\\\"\\\""},
        {"call": "longestCommonPrefix([\\\"interspecies\\\", \\\"interstellar\\\", \\\"interstate\\\"])", "expect": "\\\"inters\\\""}
      ],
      "solution": "func longestCommonPrefix(strs: Array<String>): String {\\n    if (strs.size == 0) {\\n        return \\\"\\\"\\n    }\\n    // 以第一个串为基准，逐个字符与其余串对齐\\n    let first = strs[0].toArray()\\n    var keep: Int64 = 0\\n    for (k in 0..first.size) {\\n        let c = first[k]\\n        for (t in 1..strs.size) {\\n            let other = strs[t].toArray()\\n            if (k >= other.size || other[k] != c) {\\n                return String.fromUtf8(first[0..keep].toArray())\\n            }\\n        }\\n        keep = keep + 1\\n    }\\n    return String.fromUtf8(first[0..keep].toArray())\\n}"
    },
    {
      "id": 8,
      "title": "有效的回文",
      "difficulty": "简单",
      "category": "字符串",
      "funcName": "isPalindrome",
      "description": "给定一个字符串 s，判断它是否为回文串（正着读和反着读都一样）。本题只考虑小写字母，不考虑空格与标点。",
      "template": "func isPalindrome(s: String): Bool {\n    // 请在这里实现算法（提示：双指针）\n    return false\n}",
      "tests": [
        {"call": "isPalindrome(\\\"level\\\")", "expect": "true"},
        {"call": "isPalindrome(\\\"hello\\\")", "expect": "false"},
        {"call": "isPalindrome(\\\"abba\\\")", "expect": "true"}
      ],
      "solution": "func isPalindrome(s: String): Bool {\\n    // 双指针从两端向中间收，逐字节比较（本题只考虑小写字母）\\n    let bytes = s.toArray()\\n    var left: Int64 = 0\\n    var right = bytes.size - 1\\n    while (left < right) {\\n        if (bytes[left] != bytes[right]) {\\n            return false\\n        }\\n        left = left + 1\\n        right = right - 1\\n    }\\n    return true\\n}"
    },
    {
      "id": 9,
      "title": "有效的括号",
      "difficulty": "简单",
      "category": "栈与队列",
      "funcName": "isValid",
      "description": "给定一个只包括 '('、')'、'['、']'、'{'、'}' 的字符串 s，判断字符串是否有效。\n有效字符串需满足：左括号必须用相同类型的右括号闭合，且必须以正确的顺序闭合。",
      "template": "func isValid(s: String): Bool {\n    // 请在这里实现算法（提示：栈）\n    return false\n}",
      "tests": [
        {"call": "isValid(\\\"()\\\")", "expect": "true"},
        {"call": "isValid(\\\"()[]{}\\\")", "expect": "true"},
        {"call": "isValid(\\\"(]\\\")", "expect": "false"},
        {"call": "isValid(\\\"([)]\\\")", "expect": "false"},
        {"call": "isValid(\\\"{[]}\\\")", "expect": "true"}
      ],
      "solution": "func isValid(s: String): Bool {\\n    // 栈：左括号压栈，右括号弹栈配对\\n    let bytes = s.toArray()\\n    let stack = ArrayList<UInt8>()\\n    for (c in bytes) {\\n        if (c == 40 || c == 91 || c == 123) {\\n            stack.add(c)\\n        } else {\\n            if (stack.size == 0) {\\n                return false\\n            }\\n            let top = stack[stack.size - 1]\\n            // 40=() 91=[] 123={}：右括号要与栈顶同型\\n            let ok = (c == 41 && top == 40) || (c == 93 && top == 91) || (c == 125 && top == 123)\\n            if (!ok) {\\n                return false\\n            }\\n            stack.remove(at: stack.size - 1)\\n        }\\n    }\\n    return stack.size == 0\\n}"
    },
    {
      "id": 10,
      "title": "最小栈",
      "difficulty": "中等",
      "category": "栈与队列",
      "funcName": "minStackFinal",
      "description": "设计一个支持 push、pop、getMin 操作的栈：依次执行给定操作序列后，返回最后的 getMin 结果。\nopSeq 是操作序列：正整数 n 表示 push(n)，-1 表示 pop（弹出栈顶），-2 表示查询当前栈内最小值；把每次 -2 查询的结果按序拼接返回（只留最后一次查询的结果）。",
      "template": "func minStackFinal(ops: Array<Int64>): Int64 {\n    // 请在这里实现算法（提示：辅助栈存每一步的最小值；-1 pop、-2 getMin）\n    return 0\n}",
      "tests": [
        {"call": "minStackFinal([5, -2, 3, -2, 7, -2])", "expect": "3"},
        {"call": "minStackFinal([2, 1, -2, -1, 4, -2])", "expect": "2"},
        {"call": "minStackFinal([9, -2])", "expect": "9"}
      ],
      "solution": "func minStackFinal(ops: Array<Int64>): Int64 {\\n    // 主栈 + 辅助栈（每压一个数，辅助栈同步压「当前最小」）\\n    let stack = ArrayList<Int64>()\\n    let mins = ArrayList<Int64>()\\n    var last = 0\\n    for (op in ops) {\\n        if (op == -2) {\\n            if (mins.size > 0) {\\n                last = mins[mins.size - 1]\\n            }\\n        } else if (op == -1) {\\n            if (stack.size > 0) {\\n                stack.remove(at: stack.size - 1)\\n                mins.remove(at: mins.size - 1)\\n            }\\n        } else {\\n            stack.add(op)\\n            var m = op\\n            if (mins.size > 0 && mins[mins.size - 1] < m) {\\n                m = mins[mins.size - 1]\\n            }\\n            mins.add(m)\\n        }\\n    }\\n    return last\\n}"
    },
    {
      "id": 11,
      "title": "二分查找",
      "difficulty": "简单",
      "category": "二分与排序",
      "funcName": "search",
      "description": "给定一个 n 个元素有序（升序）整型数组 nums 和一个目标值 target，写一个函数搜索 nums 中的 target，如果目标值存在返回下标，否则返回 -1。",
      "template": "func search(nums: Array<Int64>, target: Int64): Int64 {\n    // 请在这里实现算法（提示：二分）\n    return -1\n}",
      "tests": [
        {"call": "search([-1, 0, 3, 5, 9, 12], 9)", "expect": "4"},
        {"call": "search([-1, 0, 3, 5, 9, 12], 2)", "expect": "-1"},
        {"call": "search([5], 5)", "expect": "0"}
      ],
      "solution": "func search(nums: Array<Int64>, target: Int64): Int64 {\\n    var lo: Int64 = 0\\n    var hi = nums.size - 1\\n    while (lo <= hi) {\\n        let mid = (lo + hi) / 2\\n        if (nums[mid] == target) {\\n            return mid\\n        } else if (nums[mid] < target) {\\n            lo = mid + 1\\n        } else {\\n            hi = mid - 1\\n        }\\n    }\\n    return -1\\n}"
    },
    {
      "id": 12,
      "title": "搜索插入位置",
      "difficulty": "简单",
      "category": "二分与排序",
      "funcName": "searchInsert",
      "description": "给定一个排序数组和一个目标值，在数组中找到目标值，并返回其索引。如果目标值不存在于数组中，返回它将会被按顺序插入的位置。算法必须为 O(log n) 级别。",
      "template": "func searchInsert(nums: Array<Int64>, target: Int64): Int64 {\n    // 请在这里实现算法（提示：二分）\n    return 0\n}",
      "tests": [
        {"call": "searchInsert([1, 3, 5, 6], 5)", "expect": "2"},
        {"call": "searchInsert([1, 3, 5, 6], 2)", "expect": "1"},
        {"call": "searchInsert([1, 3, 5, 6], 7)", "expect": "4"},
        {"call": "searchInsert([1, 3, 5, 6], 0)", "expect": "0"}
      ],
      "solution": "func searchInsert(nums: Array<Int64>, target: Int64): Int64 {\\n    // 二分找第一个 >= target 的位置\\n    var lo: Int64 = 0\\n    var hi = nums.size\\n    while (lo < hi) {\\n        let mid = (lo + hi) / 2\\n        if (nums[mid] < target) {\\n            lo = mid + 1\\n        } else {\\n            hi = mid\\n        }\\n    }\\n    return lo\\n}"
    },
    {
      "id": 13,
      "title": "爬楼梯",
      "difficulty": "简单",
      "category": "动态规划",
      "funcName": "climbStairs",
      "description": "假设你正在爬楼梯，需要 n 阶你才能到达楼顶。每次你可以爬 1 或 2 个台阶，你有多少种不同的方法可以爬到楼顶？",
      "template": "func climbStairs(n: Int64): Int64 {\n    // 请在这里实现算法（提示：斐波那契 / 滚动变量）\n    return 0\n}",
      "tests": [
        {"call": "climbStairs(2)", "expect": "2"},
        {"call": "climbStairs(3)", "expect": "3"},
        {"call": "climbStairs(10)", "expect": "89"},
        {"call": "climbStairs(20)", "expect": "10946"}
      ],
      "solution": "func climbStairs(n: Int64): Int64 {\\n    // 滚动变量：f(i) = f(i-1) + f(i-2)\\n    if (n <= 2) {\\n        return n\\n    }\\n    var prev: Int64 = 1\\n    var cur: Int64 = 2\\n    for (i in 3..n + 1) {\\n        let next = prev + cur\\n        prev = cur\\n        cur = next\\n    }\\n    return cur\\n}"
    },
    {
      "id": 14,
      "title": "打家劫舍",
      "difficulty": "中等",
      "category": "动态规划",
      "funcName": "rob",
      "description": "你是一个小偷，沿街有一排房屋。相邻房屋装有相互连通的防盗系统，如果两间相邻的房屋在同一晚上被闯入会自动报警。\n给定一个代表每间房屋存放金额的非负整数数组，计算不触动警报装置的情况下，一夜之内能够偷窃到的最高金额。",
      "template": "func rob(nums: Array<Int64>): Int64 {\n    // 请在这里实现算法（提示：dp[i] = max(dp[i-1], dp[i-2] + nums[i])）\n    return 0\n}",
      "tests": [
        {"call": "rob([1, 2, 3, 1])", "expect": "4"},
        {"call": "rob([2, 7, 9, 3, 1])", "expect": "12"},
        {"call": "rob([5])", "expect": "5"}
      ],
      "solution": "func rob(nums: Array<Int64>): Int64 {\\n    // 打家劫舍：dp[i] = max(dp[i-1], dp[i-2] + nums[i])，滚动变量版\\n    var prev: Int64 = 0\\n    var cur: Int64 = 0\\n    for (x in nums) {\\n        let next = if (cur > prev + x) { cur } else { prev + x }\\n        prev = cur\\n        cur = next\\n    }\\n    return cur\\n}"
    },
    {
      "id": 15,
      "title": "最大子数组和",
      "difficulty": "中等",
      "category": "动态规划",
      "funcName": "maxSubArray",
      "description": "给你一个整数数组 nums，请你找出一个具有最大和的连续子数组（子数组最少包含一个元素），返回其最大和。",
      "template": "func maxSubArray(nums: Array<Int64>): Int64 {\n    // 请在这里实现算法（提示：Kadane，前缀和 or 滚动变量）\n    return 0\n}",
      "tests": [
        {"call": "maxSubArray([-2, 1, -3, 4, -1, 2, 1, -5, 4])", "expect": "6"},
        {"call": "maxSubArray([1])", "expect": "1"},
        {"call": "maxSubArray([5, 4, -1, 7, 8])", "expect": "23"}
      ],
      "solution": "func maxSubArray(nums: Array<Int64>): Int64 {\\n    // Kadane：前缀和一路走，跌破 0 就重新起头\\n    var best = nums[0]\\n    var here: Int64 = 0\\n    for (x in nums) {\\n        if (here < 0) {\\n            here = x\\n        } else {\\n            here = here + x\\n        }\\n        if (here > best) {\\n            best = here\\n        }\\n    }\\n    return best\\n}"
    },
    {
      "id": 16,
      "title": "买卖股票的最佳时机",
      "difficulty": "简单",
      "category": "贪心",
      "funcName": "maxProfit",
      "description": "给定一个数组 prices，它的第 i 个元素是一支给定股票第 i 天的价格。你只能选择某一天买入这只股票，并选择在未来的某一个不同的日子卖出。返回你能获取的最大利润；不能获取利润则返回 0。",
      "template": "func maxProfit(prices: Array<Int64>): Int64 {\n    // 请在这里实现算法（提示：记录历史最低价）\n    return 0\n}",
      "tests": [
        {"call": "maxProfit([7, 1, 5, 3, 6, 4])", "expect": "5"},
        {"call": "maxProfit([7, 6, 4, 3, 1])", "expect": "0"},
        {"call": "maxProfit([2, 4, 1])", "expect": "2"}
      ],
      "solution": "func maxProfit(prices: Array<Int64>): Int64 {\\n    // 记录历史最低价，每天算「今天卖」的最大利润\\n    var lowest = prices[0]\\n    var best: Int64 = 0\\n    for (p in prices) {\\n        if (p < lowest) {\\n            lowest = p\\n        } else if (p - lowest > best) {\\n            best = p - lowest\\n        }\\n    }\\n    return best\\n}"
    },
    {
      "id": 17,
      "title": "分发饼干",
      "difficulty": "简单",
      "category": "贪心",
      "funcName": "findContentChildren",
      "description": "假设你是一位家长，要给孩子分饼干。每个孩子最多只能给一块饼干。g[i] 是第 i 个孩子的胃口值，s[j] 是第 j 块饼干的尺寸；只有饼干尺寸大于等于孩子的胃口值时孩子才满足。\n返回尽可能多的满足孩子的数量。",
      "template": "func findContentChildren(g: Array<Int64>, s: Array<Int64>): Int64 {\n    // 请在这里实现算法（提示：两个数组都排序后双指针贪心）\n    return 0\n}",
      "tests": [
        {"call": "findContentChildren([1, 2, 3], [1, 1])", "expect": "1"},
        {"call": "findContentChildren([1, 2], [1, 2, 3])", "expect": "2"},
        {"call": "findContentChildren([10, 9, 8, 7], [5, 6, 7, 8])", "expect": "2"}
      ],
      "solution": "func findContentChildren(g: Array<Int64>, s: Array<Int64>): Int64 {\\n    // 两个数组都升序排好后双指针：最小的饼干喂给胃口最小且能饱的孩子\\n    let kids = ArrayList<Int64>()\\n    for (x in g) { kids.add(x) }\\n    let cookies = ArrayList<Int64>()\\n    for (x in s) { cookies.add(x) }\\n    sortAsc(kids)\\n    sortAsc(cookies)\\n    var i: Int64 = 0\\n    var j: Int64 = 0\\n    var fed: Int64 = 0\\n    while (i < kids.size && j < cookies.size) {\\n        if (cookies[j] >= kids[i]) {\\n            fed = fed + 1\\n            i = i + 1\\n        }\\n        j = j + 1\\n    }\\n    return fed\\n}\\n\\n/** 升序插入排序（数组规模小，简单可靠优先） */\\nfunc sortAsc(a: ArrayList<Int64>): Unit {\\n    for (i in 1..a.size) {\\n        var j = i\\n        while (j > 0 && a[j - 1] > a[j]) {\\n            let tmp = a[j - 1]\\n            a[j - 1] = a[j]\\n            a[j] = tmp\\n            j = j - 1\\n        }\\n    }\\n}"
    },
    {
      "id": 18,
      "title": "只出现一次的数字",
      "difficulty": "简单",
      "category": "位运算与数学",
      "funcName": "singleNumber",
      "description": "给定一个非空整型数组，除了某个元素只出现一次以外，其余每个元素均出现两次。找出那个只出现了一次的元素。要求线性时间复杂度、不使用额外空间。",
      "template": "func singleNumber(nums: Array<Int64>): Int64 {\n    // 请在这里实现算法（提示：异或）\n    return 0\n}",
      "tests": [
        {"call": "singleNumber([2, 2, 1])", "expect": "1"},
        {"call": "singleNumber([4, 1, 2, 1, 2])", "expect": "4"},
        {"call": "singleNumber([1])", "expect": "1"}
      ],
      "solution": "func singleNumber(nums: Array<Int64>): Int64 {\\n    // 异或：相同的抵消成 0，剩下那个就是答案\\n    var acc: Int64 = 0\\n    for (x in nums) {\\n        acc = acc ^ x\\n    }\\n    return acc\\n}"
    },
    {
      "id": 19,
      "title": "计数质数",
      "difficulty": "中等",
      "category": "位运算与数学",
      "funcName": "countPrimes",
      "description": "给定整数 n，返回所有严格小于 n 的质数的数量。",
      "template": "func countPrimes(n: Int64): Int64 {\n    // 请在这里实现算法（提示：埃氏筛）\n    return 0\n}",
      "tests": [
        {"call": "countPrimes(10)", "expect": "4"},
        {"call": "countPrimes(0)", "expect": "0"},
        {"call": "countPrimes(1)", "expect": "0"},
        {"call": "countPrimes(100)", "expect": "25"}
      ],
      "solution": "func countPrimes(n: Int64): Int64 {\\n    // 埃氏筛：从 2 起，把每个质数的倍数划掉\\n    if (n <= 2) {\\n        return 0\\n    }\\n    let composite = Array<Bool>(n, repeat: false)\\n    var count: Int64 = 0\\n    for (i in 2..n) {\\n        if (!composite[i]) {\\n            count = count + 1\\n            var j = i * i\\n            while (j < n) {\\n                composite[j] = true\\n                j = j + i\\n            }\\n        }\\n    }\\n    return count\\n}"
    },
    {
      "id": 20,
      "title": "存在重复元素",
      "difficulty": "简单",
      "category": "哈希与计数",
      "funcName": "containsDuplicate",
      "description": "给定一个整数数组 nums，判断其中是否存在重复元素：只要有任意一个元素出现至少两次就返回 true，否则返回 false。",
      "template": "func containsDuplicate(nums: Array<Int64>): Bool {\\n    // 请在这里实现算法（提示：哈希集合去重）\\n    return false\\n}",
      "tests": [
        {"call": "containsDuplicate([1, 2, 3, 1])", "expect": "true"},
        {"call": "containsDuplicate([1, 2, 3, 4])", "expect": "false"},
        {"call": "containsDuplicate([1, 1, 1, 3, 3, 4, 3, 2, 4, 2])", "expect": "true"}
      ],
      "solution": "func containsDuplicate(nums: Array<Int64>): Bool {\\n    let seen = HashSet<Int64>()\\n    for (x in nums) {\\n        if (seen.contains(x)) {\\n            return true\\n        }\\n        seen.add(x)\\n    }\\n    return false\\n}"
    },
    {
      "id": 21,
      "title": "两个数组的交集",
      "difficulty": "简单",
      "category": "哈希与计数",
      "funcName": "intersection",
      "description": "给定两个整数数组 nums1、nums2，返回它们的交集。结果按元素在 nums1 中首次出现的顺序排列，且不含重复元素。",
      "template": "func intersection(nums1: Array<Int64>, nums2: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：哈希集合去重，按 nums1 顺序输出）\\n    return []\\n}",
      "tests": [
        {"call": "intersection([1, 2, 2, 1], [2, 2])", "expect": "[2]"},
        {"call": "intersection([4, 9, 5], [9, 4, 9, 8, 4])", "expect": "[4, 9]"},
        {"call": "intersection([1, 2, 3], [4, 5, 6])", "expect": "[]"}
      ],
      "solution": "func intersection(nums1: Array<Int64>, nums2: Array<Int64>): Array<Int64> {\\n    let has = HashSet<Int64>()\\n    for (x in nums2) {\\n        has.add(x)\\n    }\\n    let used = HashSet<Int64>()\\n    let out = ArrayList<Int64>()\\n    for (x in nums1) {\\n        if (has.contains(x) && !used.contains(x)) {\\n            used.add(x)\\n            out.add(x)\\n        }\\n    }\\n    return out.toArray()\\n}"
    },
    {
      "id": 22,
      "title": "快乐数",
      "difficulty": "简单",
      "category": "哈希与计数",
      "funcName": "isHappy",
      "description": "快乐数的判定方式：把整数反复替换成它各位数字的平方和，如果最终能变成 1 就是快乐数；如果陷入不包含 1 的循环则不是。",
      "template": "func isHappy(n: Int64): Bool {\\n    // 请在这里实现算法（提示：逐位平方和 + 环检测）\\n    return false\\n}",
      "tests": [
        {"call": "isHappy(19)", "expect": "true"},
        {"call": "isHappy(2)", "expect": "false"},
        {"call": "isHappy(1)", "expect": "true"},
        {"call": "isHappy(7)", "expect": "true"}
      ],
      "solution": "func isHappy(n: Int64): Bool {\\n    let seen = HashSet<Int64>()\\n    var cur = n\\n    while (cur != 1) {\\n        if (seen.contains(cur)) {\\n            return false\\n        }\\n        seen.add(cur)\\n        var sum: Int64 = 0\\n        var x = cur\\n        while (x > 0) {\\n            let d = x % 10\\n            sum = sum + d * d\\n            x = x / 10\\n        }\\n        cur = sum\\n    }\\n    return true\\n}"
    },
    {
      "id": 23,
      "title": "同构字符串",
      "difficulty": "简单",
      "category": "哈希与计数",
      "funcName": "isIsomorphic",
      "description": "给定两个长度相同的字符串 s 和 t，判断它们是否同构：s 中的每个字符都能按同一种规则替换成 t 中对应位置的字符，且不同的字符不能映射到同一个字符。",
      "template": "func isIsomorphic(s: String, t: String): Bool {\\n    // 请在这里实现算法（提示：两个方向的映射都要一致）\\n    return false\\n}",
      "tests": [
        {"call": "isIsomorphic(\\\"egg\\\", \\\"add\\\")", "expect": "true"},
        {"call": "isIsomorphic(\\\"foo\\\", \\\"bar\\\")", "expect": "false"},
        {"call": "isIsomorphic(\\\"paper\\\", \\\"title\\\")", "expect": "true"},
        {"call": "isIsomorphic(\\\"aa\\\", \\\"ab\\\")", "expect": "false"}
      ],
      "solution": "func isIsomorphic(s: String, t: String): Bool {\\n    let a = s.toArray()\\n    let b = t.toArray()\\n    if (a.size != b.size) {\\n        return false\\n    }\\n    let forward = HashMap<UInt8, UInt8>()\\n    let backward = HashMap<UInt8, UInt8>()\\n    for (i in 0..a.size) {\\n        if (let Some(v) <- forward.get(a[i])) {\\n            if (v != b[i]) {\\n                return false\\n            }\\n        }\\n        if (let Some(w) <- backward.get(b[i])) {\\n            if (w != a[i]) {\\n                return false\\n            }\\n        }\\n        forward.add(a[i], b[i])\\n        backward.add(b[i], a[i])\\n    }\\n    return true\\n}"
    },
    {
      "id": 24,
      "title": "单词规律",
      "difficulty": "简单",
      "category": "哈希与计数",
      "funcName": "wordPattern",
      "description": "给定一个只含小写字母的模式串 pattern 和一个由空格分隔单词的字符串 s，判断 s 是否符合 pattern 的规律：同一个字母必须对应同一个单词，同一个单词也必须对应同一个字母。",
      "template": "func wordPattern(pattern: String, s: String): Bool {\\n    // 请在这里实现算法（提示：双向映射，先按空格拆词）\\n    return false\\n}",
      "tests": [
        {"call": "wordPattern(\\\"abba\\\", \\\"dog cat cat dog\\\")", "expect": "true"},
        {"call": "wordPattern(\\\"abba\\\", \\\"dog cat cat fish\\\")", "expect": "false"},
        {"call": "wordPattern(\\\"aaaa\\\", \\\"dog cat cat dog\\\")", "expect": "false"},
        {"call": "wordPattern(\\\"ab\\\", \\\"dog dog\\\")", "expect": "false"}
      ],
      "solution": "func wordPattern(pattern: String, s: String): Bool {\\n    let words = ArrayList<String>()\\n    var buf = ArrayList<UInt8>()\\n    for (c in s.toArray()) {\\n        if (c == 32) {\\n            if (buf.size > 0) {\\n                words.add(String.fromUtf8(buf.toArray()))\\n                buf = ArrayList<UInt8>()\\n            }\\n        } else {\\n            buf.add(c)\\n        }\\n    }\\n    if (buf.size > 0) {\\n        words.add(String.fromUtf8(buf.toArray()))\\n    }\\n    let pb = pattern.toArray()\\n    if (words.size != pb.size) {\\n        return false\\n    }\\n    let p2w = HashMap<UInt8, String>()\\n    let w2p = HashMap<String, UInt8>()\\n    for (i in 0..pb.size) {\\n        if (let Some(w) <- p2w.get(pb[i])) {\\n            if (w != words[i]) {\\n                return false\\n            }\\n        }\\n        if (let Some(p) <- w2p.get(words[i])) {\\n            if (p != pb[i]) {\\n                return false\\n            }\\n        }\\n        p2w.add(pb[i], words[i])\\n        w2p.add(words[i], pb[i])\\n    }\\n    return true\\n}"
    },
    {
      "id": 25,
      "title": "回旋镖的数量",
      "difficulty": "中等",
      "category": "哈希与计数",
      "funcName": "numberOfBoomerangs",
      "description": "坐标点用扁平数组给出：第 i 个点的横纵坐标分别是 points[2i] 与 points[2i+1]。若三点中某一点到另外两点的距离相等（另外两点的先后顺序不同算不同的回旋镖），就构成一个回旋镖。返回回旋镖的总数。",
      "template": "func numberOfBoomerangs(points: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：对每个中心点按距离计数）\\n    return 0\\n}",
      "tests": [
        {"call": "numberOfBoomerangs([0, 0, 1, 0, 2, 0])", "expect": "2"},
        {"call": "numberOfBoomerangs([1, 1, 2, 2, 3, 3])", "expect": "2"},
        {"call": "numberOfBoomerangs([1, 1])", "expect": "0"}
      ],
      "solution": "func numberOfBoomerangs(points: Array<Int64>): Int64 {\\n    let n = points.size / 2\\n    var total: Int64 = 0\\n    for (i in 0..n) {\\n        let counter = HashMap<Int64, Int64>()\\n        for (j in 0..n) {\\n            let dx = points[i * 2] - points[j * 2]\\n            let dy = points[i * 2 + 1] - points[j * 2 + 1]\\n            let d = dx * dx + dy * dy\\n            var cur: Int64 = 0\\n            if (let Some(v) <- counter.get(d)) {\\n                cur = v\\n            }\\n            counter.add(d, cur + 1)\\n            total = total + cur * 2\\n        }\\n    }\\n    return total\\n}"
    },
    {
      "id": 26,
      "title": "最长和谐子序列",
      "difficulty": "简单",
      "category": "哈希与计数",
      "funcName": "findLHS",
      "description": "和谐子序列指最大值与最小值之差恰好为 1 的子序列。给定整数数组 nums，返回其中最长的和谐子序列的长度；如果不存在这样的子序列则返回 0。",
      "template": "func findLHS(nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：排序后统计相邻两族）\\n    return 0\\n}",
      "tests": [
        {"call": "findLHS([1, 3, 2, 2, 5, 2, 3, 7])", "expect": "5"},
        {"call": "findLHS([1, 2, 3, 4])", "expect": "2"},
        {"call": "findLHS([1, 1, 1, 1])", "expect": "0"}
      ],
      "solution": "import std.collection.*\\nimport std.sort.*\\n\\nfunc findLHS(nums: Array<Int64>): Int64 {\\n    let a = nums.clone()\\n    sort(a)\\n    var best: Int64 = 0\\n    var i: Int64 = 0\\n    while (i < a.size) {\\n        var j = i\\n        while (j < a.size && a[j] == a[i]) {\\n            j = j + 1\\n        }\\n        var k = j\\n        while (k < a.size && a[k] == a[i] + 1) {\\n            k = k + 1\\n        }\\n        if (k > j && k - i > best) {\\n            best = k - i\\n        }\\n        i = j\\n    }\\n    return best\\n}"
    },
    {
      "id": 27,
      "title": "字母异位词分组",
      "difficulty": "中等",
      "category": "哈希与计数",
      "funcName": "countAnagramGroups",
      "description": "给定一组只含小写字母的字符串，把由相同字母重新排列得到的字符串归为同一组，返回组数。例如 eat、tea、ate 属于同一组。",
      "template": "func countAnagramGroups(strs: Array<String>): Int64 {\\n    // 请在这里实现算法（提示：排序后的字符序列当分组键）\\n    return 0\\n}",
      "tests": [
        {"call": "countAnagramGroups([\\\"eat\\\", \\\"tea\\\", \\\"tan\\\", \\\"ate\\\", \\\"nat\\\", \\\"bat\\\"])", "expect": "3"},
        {"call": "countAnagramGroups([\\\"a\\\"])", "expect": "1"},
        {"call": "countAnagramGroups([\\\"ab\\\", \\\"ba\\\", \\\"abc\\\"])", "expect": "2"}
      ],
      "solution": "import std.collection.*\\nimport std.sort.*\\n\\nfunc countAnagramGroups(strs: Array<String>): Int64 {\\n    let groups = HashSet<String>()\\n    for (s in strs) {\\n        let key = s.toArray()\\n        sort(key)\\n        groups.add(String.fromUtf8(key))\\n    }\\n    return groups.size\\n}"
    },
    {
      "id": 28,
      "title": "移除元素",
      "difficulty": "简单",
      "category": "数组与双指针",
      "funcName": "removeElement",
      "description": "给定整数数组 nums 与整数 val，原地移除所有等于 val 的元素，返回移除后数组的新长度；留下的元素顺序可以改变。",
      "template": "func removeElement(nums: Array<Int64>, val: Int64): Int64 {\\n    // 请在这里实现算法（提示：快慢指针原地覆盖）\\n    return 0\\n}",
      "tests": [
        {"call": "removeElement([3, 2, 2, 3], 3)", "expect": "2"},
        {"call": "removeElement([0, 1, 2, 2, 3, 0, 4, 2], 2)", "expect": "5"},
        {"call": "removeElement([1], 1)", "expect": "0"}
      ],
      "solution": "func removeElement(nums: Array<Int64>, val: Int64): Int64 {\\n    var k: Int64 = 0\\n    for (x in nums) {\\n        if (x != val) {\\n            nums[k] = x\\n            k = k + 1\\n        }\\n    }\\n    return k\\n}"
    },
    {
      "id": 29,
      "title": "删除有序数组中的重复项",
      "difficulty": "简单",
      "category": "数组与双指针",
      "funcName": "removeDuplicates",
      "description": "给定按升序排列的整数数组 nums，原地删除重复出现的元素，使每个元素只出现一次，返回删除后数组的新长度。要求不使用额外空间。",
      "template": "func removeDuplicates(nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：快慢指针）\\n    return 0\\n}",
      "tests": [
        {"call": "removeDuplicates([1, 1, 2])", "expect": "2"},
        {"call": "removeDuplicates([0, 0, 1, 1, 1, 2, 2, 3, 3, 4])", "expect": "5"},
        {"call": "removeDuplicates([1])", "expect": "1"}
      ],
      "solution": "func removeDuplicates(nums: Array<Int64>): Int64 {\\n    if (nums.size == 0) {\\n        return 0\\n    }\\n    var k: Int64 = 1\\n    for (i in 1..nums.size) {\\n        if (nums[i] != nums[k - 1]) {\\n            nums[k] = nums[i]\\n            k = k + 1\\n        }\\n    }\\n    return k\\n}"
    },
    {
      "id": 30,
      "title": "有序数组的平方",
      "difficulty": "简单",
      "category": "数组与双指针",
      "funcName": "sortedSquares",
      "description": "给定一个按非递减顺序排列的整数数组 nums，返回每个数字的平方组成的新数组，要求新数组也按非递减顺序排列。",
      "template": "func sortedSquares(nums: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：首尾双指针从大往小填）\\n    return []\\n}",
      "tests": [
        {"call": "sortedSquares([-4, -1, 0, 3, 10])", "expect": "[0, 1, 9, 16, 100]"},
        {"call": "sortedSquares([-7, -3, 2, 3, 11])", "expect": "[4, 9, 9, 49, 121]"},
        {"call": "sortedSquares([0])", "expect": "[0]"}
      ],
      "solution": "func sortedSquares(nums: Array<Int64>): Array<Int64> {\\n    let n = nums.size\\n    let out = Array<Int64>(n, repeat: 0)\\n    var i: Int64 = 0\\n    var j: Int64 = n - 1\\n    var k: Int64 = n - 1\\n    while (i <= j) {\\n        let a = nums[i] * nums[i]\\n        let b = nums[j] * nums[j]\\n        if (a >= b) {\\n            out[k] = a\\n            i = i + 1\\n        } else {\\n            out[k] = b\\n            j = j - 1\\n        }\\n        k = k - 1\\n    }\\n    return out\\n}"
    },
    {
      "id": 31,
      "title": "三数之和的个数",
      "difficulty": "中等",
      "category": "数组与双指针",
      "funcName": "threeSumCount",
      "description": "给定整数数组 nums，统计所有和为 0 的三元组个数。三元组按数值去重：同样的三个数只算一次，与它们在数组中的下标无关。",
      "template": "func threeSumCount(nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：排序 + 双指针，数值三元组去重）\\n    return 0\\n}",
      "tests": [
        {"call": "threeSumCount([-1, 0, 1, 2, -1, -4])", "expect": "2"},
        {"call": "threeSumCount([0, 0, 0])", "expect": "1"},
        {"call": "threeSumCount([1, 2, 3])", "expect": "0"},
        {"call": "threeSumCount([-2, 0, 1, 1, 2])", "expect": "2"}
      ],
      "solution": "import std.collection.*\\nimport std.sort.*\\n\\nfunc threeSumCount(nums: Array<Int64>): Int64 {\\n    let a = nums.clone()\\n    sort(a)\\n    var count: Int64 = 0\\n    var i: Int64 = 0\\n    while (i < a.size) {\\n        if (i > 0 && a[i] == a[i - 1]) {\\n            i = i + 1\\n            continue\\n        }\\n        var l = i + 1\\n        var r = a.size - 1\\n        while (l < r) {\\n            let s = a[i] + a[l] + a[r]\\n            if (s == 0) {\\n                count = count + 1\\n                while (l < r && a[l] == a[l + 1]) {\\n                    l = l + 1\\n                }\\n                while (l < r && a[r] == a[r - 1]) {\\n                    r = r - 1\\n                }\\n                l = l + 1\\n                r = r - 1\\n            } else if (s < 0) {\\n                l = l + 1\\n            } else {\\n                r = r - 1\\n            }\\n        }\\n        i = i + 1\\n    }\\n    return count\\n}"
    },
    {
      "id": 32,
      "title": "最接近的三数之和",
      "difficulty": "中等",
      "category": "数组与双指针",
      "funcName": "threeSumClosest",
      "description": "给定整数数组 nums 与目标值 target，从数组中选出三个数，使它们的和最接近 target（假设每组输入只有唯一答案）。返回这个和。",
      "template": "func threeSumClosest(nums: Array<Int64>, target: Int64): Int64 {\\n    // 请在这里实现算法（提示：排序 + 双指针逼近）\\n    return 0\\n}",
      "tests": [
        {"call": "threeSumClosest([-1, 2, 1, -4], 1)", "expect": "2"},
        {"call": "threeSumClosest([0, 0, 0], 1)", "expect": "0"},
        {"call": "threeSumClosest([1, 1, 1, 0], -100)", "expect": "2"}
      ],
      "solution": "import std.collection.*\\nimport std.sort.*\\n\\nfunc threeSumClosest(nums: Array<Int64>, target: Int64): Int64 {\\n    let a = nums.clone()\\n    sort(a)\\n    var best = a[0] + a[1] + a[2]\\n    var i: Int64 = 0\\n    while (i < a.size - 2) {\\n        var l = i + 1\\n        var r = a.size - 1\\n        while (l < r) {\\n            let s = a[i] + a[l] + a[r]\\n            if (s == target) {\\n                return s\\n            }\\n            let d1 = (s - target) * (s - target)\\n            let d2 = (best - target) * (best - target)\\n            if (d1 < d2) {\\n                best = s\\n            }\\n            if (s < target) {\\n                l = l + 1\\n            } else {\\n                r = r - 1\\n            }\\n        }\\n        i = i + 1\\n    }\\n    return best\\n}"
    },
    {
      "id": 33,
      "title": "颜色分类",
      "difficulty": "中等",
      "category": "数组与双指针",
      "funcName": "sortColors",
      "description": "给定一个只包含 0、1、2 的整数数组，按 0、1、2 的顺序排序，返回排序后的新数组（不要求原地修改）。",
      "template": "func sortColors(nums: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：统计三种颜色后重建数组）\\n    return []\\n}",
      "tests": [
        {"call": "sortColors([2, 0, 2, 1, 1, 0])", "expect": "[0, 0, 1, 1, 2, 2]"},
        {"call": "sortColors([2, 0, 1])", "expect": "[0, 1, 2]"},
        {"call": "sortColors([1, 2, 0, 0])", "expect": "[0, 0, 1, 2]"}
      ],
      "solution": "func sortColors(nums: Array<Int64>): Array<Int64> {\\n    var c0: Int64 = 0\\n    var c1: Int64 = 0\\n    var c2: Int64 = 0\\n    for (x in nums) {\\n        if (x == 0) {\\n            c0 = c0 + 1\\n        } else if (x == 1) {\\n            c1 = c1 + 1\\n        } else {\\n            c2 = c2 + 1\\n        }\\n    }\\n    let out = ArrayList<Int64>()\\n    for (_ in 0..c0) {\\n        out.add(0)\\n    }\\n    for (_ in 0..c1) {\\n        out.add(1)\\n    }\\n    for (_ in 0..c2) {\\n        out.add(2)\\n    }\\n    return out.toArray()\\n}"
    },
    {
      "id": 34,
      "title": "合并区间",
      "difficulty": "中等",
      "category": "数组与双指针",
      "funcName": "mergeIntervalCount",
      "description": "区间用扁平数组给出：第 i 个区间是 [intervals[2i], intervals[2i+1]]。合并所有互相重叠的区间，返回合并后区间的个数（区间为闭区间，端点相接也算重叠）。",
      "template": "func mergeIntervalCount(intervals: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：按起点排序后一次扫描）\\n    return 0\\n}",
      "tests": [
        {"call": "mergeIntervalCount([1, 3, 2, 6, 8, 10, 15, 18])", "expect": "3"},
        {"call": "mergeIntervalCount([1, 4, 4, 5])", "expect": "1"},
        {"call": "mergeIntervalCount([1, 2, 3, 4])", "expect": "2"}
      ],
      "solution": "func mergeIntervalCount(intervals: Array<Int64>): Int64 {\\n    let n = intervals.size / 2\\n    let a = intervals.clone()\\n    // 按起点做选择排序（成对交换）\\n    var i: Int64 = 0\\n    while (i < n) {\\n        var m = i\\n        var j = i + 1\\n        while (j < n) {\\n            if (a[j * 2] < a[m * 2]) {\\n                m = j\\n            }\\n            j = j + 1\\n        }\\n        if (m != i) {\\n            let s = a[i * 2]\\n            let e = a[i * 2 + 1]\\n            a[i * 2] = a[m * 2]\\n            a[i * 2 + 1] = a[m * 2 + 1]\\n            a[m * 2] = s\\n            a[m * 2 + 1] = e\\n        }\\n        i = i + 1\\n    }\\n    var count: Int64 = 0\\n    var curEnd: Int64 = 0\\n    var k: Int64 = 0\\n    while (k < n) {\\n        if (k == 0 || a[k * 2] > curEnd) {\\n            count = count + 1\\n            curEnd = a[k * 2 + 1]\\n        } else if (a[k * 2 + 1] > curEnd) {\\n            curEnd = a[k * 2 + 1]\\n        }\\n        k = k + 1\\n    }\\n    return count\\n}"
    },
    {
      "id": 35,
      "title": "轮转数组",
      "difficulty": "中等",
      "category": "数组与双指针",
      "funcName": "rotate",
      "description": "给定整数数组 nums，把数组中的元素向右轮转 k 个位置（k 可以大于数组长度），返回轮转后的数组。",
      "template": "func rotate(nums: Array<Int64>, k: Int64): Array<Int64> {\\n    // 请在这里实现算法（提示：整体反转 + 两段分别反转）\\n    return []\\n}",
      "tests": [
        {"call": "rotate([1, 2, 3, 4, 5, 6, 7], 3)", "expect": "[5, 6, 7, 1, 2, 3, 4]"},
        {"call": "rotate([-1, -100, 3, 99], 2)", "expect": "[3, 99, -1, -100]"},
        {"call": "rotate([1, 2], 0)", "expect": "[1, 2]"}
      ],
      "solution": "func reversePart(a: Array<Int64>, lo: Int64, hi: Int64): Unit {\\n    var i = lo\\n    var j = hi\\n    while (i < j) {\\n        let t = a[i]\\n        a[i] = a[j]\\n        a[j] = t\\n        i = i + 1\\n        j = j - 1\\n    }\\n}\\n\\nfunc rotate(nums: Array<Int64>, k: Int64): Array<Int64> {\\n    let n = nums.size\\n    let a = nums.clone()\\n    if (n == 0) {\\n        return a\\n    }\\n    let s = k % n\\n    if (s == 0) {\\n        return a\\n    }\\n    reversePart(a, 0, n - 1)\\n    reversePart(a, 0, s - 1)\\n    reversePart(a, s, n - 1)\\n    return a\\n}"
    },
    {
      "id": 36,
      "title": "长度最小的子数组",
      "difficulty": "中等",
      "category": "数组与双指针",
      "funcName": "minSubArrayLen",
      "description": "给定正整数数组 nums 与正整数 target，找出数组中总和大于等于 target 的最短连续子数组，返回它的长度；不存在则返回 0。",
      "template": "func minSubArrayLen(target: Int64, nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：滑动窗口收放）\\n    return 0\\n}",
      "tests": [
        {"call": "minSubArrayLen(7, [2, 3, 1, 2, 4, 3])", "expect": "2"},
        {"call": "minSubArrayLen(4, [1, 4, 4])", "expect": "1"},
        {"call": "minSubArrayLen(11, [1, 1, 1, 1, 1, 1, 1, 1])", "expect": "0"}
      ],
      "solution": "func minSubArrayLen(target: Int64, nums: Array<Int64>): Int64 {\\n    var best = nums.size + 1\\n    var sum: Int64 = 0\\n    var lo: Int64 = 0\\n    var hi: Int64 = 0\\n    while (hi < nums.size) {\\n        sum = sum + nums[hi]\\n        while (sum >= target) {\\n            if (hi - lo + 1 < best) {\\n                best = hi - lo + 1\\n            }\\n            sum = sum - nums[lo]\\n            lo = lo + 1\\n        }\\n        hi = hi + 1\\n    }\\n    if (best > nums.size) {\\n        return 0\\n    }\\n    return best\\n}"
    },
    {
      "id": 37,
      "title": "无重复字符的最长子串",
      "difficulty": "中等",
      "category": "数组与双指针",
      "funcName": "lengthOfLongestSubstring",
      "description": "给定一个字符串 s，找出其中不含重复字符的最长连续子串的长度。字符串只包含 ASCII 字符。",
      "template": "func lengthOfLongestSubstring(s: String): Int64 {\\n    // 请在这里实现算法（提示：窗口左界只增不减 + 记录上次位置）\\n    return 0\\n}",
      "tests": [
        {"call": "lengthOfLongestSubstring(\\\"abcabcbb\\\")", "expect": "3"},
        {"call": "lengthOfLongestSubstring(\\\"bbbbb\\\")", "expect": "1"},
        {"call": "lengthOfLongestSubstring(\\\"pwwkew\\\")", "expect": "3"},
        {"call": "lengthOfLongestSubstring(\\\"\\\")", "expect": "0"}
      ],
      "solution": "func lengthOfLongestSubstring(s: String): Int64 {\\n    let b = s.toArray()\\n    let last = HashMap<UInt8, Int64>()\\n    var best: Int64 = 0\\n    var start: Int64 = 0\\n    var i: Int64 = 0\\n    while (i < b.size) {\\n        if (let Some(p) <- last.get(b[i])) {\\n            if (p + 1 > start) {\\n                start = p + 1\\n            }\\n        }\\n        last.add(b[i], i)\\n        if (i - start + 1 > best) {\\n            best = i - start + 1\\n        }\\n        i = i + 1\\n    }\\n    return best\\n}"
    },
    {
      "id": 38,
      "title": "找到字符串中所有字母异位词",
      "difficulty": "中等",
      "category": "数组与双指针",
      "funcName": "countAnagrams",
      "description": "给定字符串 s 与 p（均只含小写字母），统计 s 中所有与 p 互为字母异位词的子串个数——子串长度与 p 相同且各字母出现次数一致。",
      "template": "func countAnagrams(s: String, p: String): Int64 {\\n    // 请在这里实现算法（提示：定长窗口 + 26 个字母计数）\\n    return 0\\n}",
      "tests": [
        {"call": "countAnagrams(\\\"cbaebabacd\\\", \\\"abc\\\")", "expect": "2"},
        {"call": "countAnagrams(\\\"abab\\\", \\\"ab\\\")", "expect": "3"},
        {"call": "countAnagrams(\\\"aa\\\", \\\"bb\\\")", "expect": "0"}
      ],
      "solution": "func countAnagrams(s: String, p: String): Int64 {\\n    let bs = s.toArray()\\n    let bp = p.toArray()\\n    let n = bs.size\\n    let m = bp.size\\n    if (m > n) {\\n        return 0\\n    }\\n    let need = Array<Int64>(26, repeat: 0)\\n    for (c in bp) {\\n        let k = Int64(c) - 97\\n        need[k] = need[k] + 1\\n    }\\n    let win = Array<Int64>(26, repeat: 0)\\n    var count: Int64 = 0\\n    var i: Int64 = 0\\n    while (i < n) {\\n        win[Int64(bs[i]) - 97] = win[Int64(bs[i]) - 97] + 1\\n        if (i >= m) {\\n            win[Int64(bs[i - m]) - 97] = win[Int64(bs[i - m]) - 97] - 1\\n        }\\n        if (i >= m - 1) {\\n            var same = true\\n            for (j in 0..26) {\\n                if (need[j] != win[j]) {\\n                    same = false\\n                }\\n            }\\n            if (same) {\\n                count = count + 1\\n            }\\n        }\\n        i = i + 1\\n    }\\n    return count\\n}"
    },
    {
      "id": 39,
      "title": "最大连续 1 的个数",
      "difficulty": "简单",
      "category": "数组与双指针",
      "funcName": "findMaxConsecutiveOnes",
      "description": "给定一个只包含 0 和 1 的数组，返回其中连续 1 的最大个数。",
      "template": "func findMaxConsecutiveOnes(nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：一次遍历维护当前段长）\\n    return 0\\n}",
      "tests": [
        {"call": "findMaxConsecutiveOnes([1, 1, 0, 1, 1, 1])", "expect": "3"},
        {"call": "findMaxConsecutiveOnes([1, 0, 1, 1, 0, 1])", "expect": "2"},
        {"call": "findMaxConsecutiveOnes([0])", "expect": "0"}
      ],
      "solution": "func findMaxConsecutiveOnes(nums: Array<Int64>): Int64 {\\n    var best: Int64 = 0\\n    var cur: Int64 = 0\\n    for (x in nums) {\\n        if (x == 1) {\\n            cur = cur + 1\\n            if (cur > best) {\\n                best = cur\\n            }\\n        } else {\\n            cur = 0\\n        }\\n    }\\n    return best\\n}"
    },
    {
      "id": 40,
      "title": "第三大的数",
      "difficulty": "简单",
      "category": "数组与双指针",
      "funcName": "thirdMax",
      "description": "给定非空整数数组 nums，返回其中第三大的数；如果不存在第三大的数，则返回最大的数。要求按不同的数值计数（相等的元素只算一个）。",
      "template": "func thirdMax(nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：去重后排序取第三大）\\n    return 0\\n}",
      "tests": [
        {"call": "thirdMax([3, 2, 1])", "expect": "1"},
        {"call": "thirdMax([1, 2])", "expect": "2"},
        {"call": "thirdMax([2, 2, 3, 1])", "expect": "1"},
        {"call": "thirdMax([1, 2, 3, 3])", "expect": "1"}
      ],
      "solution": "import std.collection.*\\nimport std.sort.*\\n\\nfunc thirdMax(nums: Array<Int64>): Int64 {\\n    let seen = HashSet<Int64>()\\n    let uniq = ArrayList<Int64>()\\n    for (x in nums) {\\n        if (!seen.contains(x)) {\\n            seen.add(x)\\n            uniq.add(x)\\n        }\\n    }\\n    let a = uniq.toArray()\\n    sort(a)\\n    if (a.size >= 3) {\\n        return a[a.size - 3]\\n    }\\n    return a[a.size - 1]\\n}"
    },
    {
      "id": 41,
      "title": "多数元素 II",
      "difficulty": "中等",
      "category": "数组与双指针",
      "funcName": "majorityElements",
      "description": "给定整数数组 nums，返回其中所有出现次数严格大于长度三分之一的元素，结果按升序排列。",
      "template": "func majorityElements(nums: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：计数后筛出超过三分之一的元素）\\n    return []\\n}",
      "tests": [
        {"call": "majorityElements([3, 2, 3])", "expect": "[3]"},
        {"call": "majorityElements([1])", "expect": "[1]"},
        {"call": "majorityElements([1, 1, 1, 3, 3, 2, 2, 2])", "expect": "[1, 2]"}
      ],
      "solution": "import std.collection.*\\nimport std.sort.*\\n\\nfunc majorityElements(nums: Array<Int64>): Array<Int64> {\\n    let counter = HashMap<Int64, Int64>()\\n    for (x in nums) {\\n        var cur: Int64 = 0\\n        if (let Some(v) <- counter.get(x)) {\\n            cur = v\\n        }\\n        counter.add(x, cur + 1)\\n    }\\n    let out = ArrayList<Int64>()\\n    let limit = nums.size / 3\\n    for ((k, v) in counter) {\\n        if (v > limit) {\\n            out.add(k)\\n        }\\n    }\\n    let a = out.toArray()\\n    sort(a)\\n    return a\\n}"
    },
    {
      "id": 42,
      "title": "实现 strStr",
      "difficulty": "简单",
      "category": "字符串",
      "funcName": "strStr",
      "description": "给定两个字符串 haystack 与 needle，返回 needle 在 haystack 中第一次出现的下标；不存在则返回 -1，needle 为空串时返回 0。字符串只含小写字母。",
      "template": "func strStr(haystack: String, needle: String): Int64 {\\n    // 请在这里实现算法（提示：朴素匹配，逐位比较）\\n    return -1\\n}",
      "tests": [
        {"call": "strStr(\\\"sadbutsad\\\", \\\"sad\\\")", "expect": "0"},
        {"call": "strStr(\\\"leetcode\\\", \\\"leeto\\\")", "expect": "-1"},
        {"call": "strStr(\\\"hello\\\", \\\"\\\")", "expect": "0"}
      ],
      "solution": "func strStr(haystack: String, needle: String): Int64 {\\n    let h = haystack.toArray()\\n    let n = needle.toArray()\\n    if (n.size == 0) {\\n        return 0\\n    }\\n    if (n.size > h.size) {\\n        return -1\\n    }\\n    var i: Int64 = 0\\n    while (i + n.size <= h.size) {\\n        var j: Int64 = 0\\n        var ok = true\\n        while (j < n.size) {\\n            if (h[i + j] != n[j]) {\\n                ok = false\\n                break\\n            }\\n            j = j + 1\\n        }\\n        if (ok) {\\n            return i\\n        }\\n        i = i + 1\\n    }\\n    return -1\\n}"
    },
    {
      "id": 43,
      "title": "最后一个单词的长度",
      "difficulty": "简单",
      "category": "字符串",
      "funcName": "lengthOfLastWord",
      "description": "给定由字母和空格组成的字符串 s，返回其中最后一个单词的长度。单词指仅由字母组成、不含空格的连续子串。",
      "template": "func lengthOfLastWord(s: String): Int64 {\\n    // 请在这里实现算法（提示：从后往前跳过空格再数）\\n    return 0\\n}",
      "tests": [
        {"call": "lengthOfLastWord(\\\"Hello World\\\")", "expect": "5"},
        {"call": "lengthOfLastWord(\\\"   fly me   to   the moon  \\\")", "expect": "4"},
        {"call": "lengthOfLastWord(\\\"luffy is still joyboy\\\")", "expect": "6"}
      ],
      "solution": "func lengthOfLastWord(s: String): Int64 {\\n    let b = s.toArray()\\n    var i = b.size - 1\\n    while (i >= 0 && b[i] == 32) {\\n        i = i - 1\\n    }\\n    var n: Int64 = 0\\n    while (i >= 0 && b[i] != 32) {\\n        n = n + 1\\n        i = i - 1\\n    }\\n    return n\\n}"
    },
    {
      "id": 44,
      "title": "验证回文串 II",
      "difficulty": "简单",
      "category": "字符串",
      "funcName": "validPalindrome",
      "description": "给定一个字符串 s，最多可以从中删除一个字符，判断能否把它变成回文串。字符串只含小写字母。",
      "template": "func validPalindrome(s: String): Bool {\\n    // 请在这里实现算法（提示：双指针撞上不等时，允许删左或删右）\\n    return false\\n}",
      "tests": [
        {"call": "validPalindrome(\\\"aba\\\")", "expect": "true"},
        {"call": "validPalindrome(\\\"abca\\\")", "expect": "true"},
        {"call": "validPalindrome(\\\"abc\\\")", "expect": "false"}
      ],
      "solution": "func isPalRange(b: Array<UInt8>, lo: Int64, hi: Int64): Bool {\\n    var i = lo\\n    var j = hi\\n    while (i < j) {\\n        if (b[i] != b[j]) {\\n            return false\\n        }\\n        i = i + 1\\n        j = j - 1\\n    }\\n    return true\\n}\\n\\nfunc validPalindrome(s: String): Bool {\\n    let b = s.toArray()\\n    var i: Int64 = 0\\n    var j = b.size - 1\\n    while (i < j) {\\n        if (b[i] != b[j]) {\\n            return isPalRange(b, i + 1, j) || isPalRange(b, i, j - 1)\\n        }\\n        i = i + 1\\n        j = j - 1\\n    }\\n    return true\\n}"
    },
    {
      "id": 45,
      "title": "字符串中的第一个唯一字符",
      "difficulty": "简单",
      "category": "字符串",
      "funcName": "firstUniqChar",
      "description": "给定一个只含小写字母的字符串 s，找到它的第一个不重复字符并返回其下标；不存在则返回 -1。",
      "template": "func firstUniqChar(s: String): Int64 {\\n    // 请在这里实现算法（提示：先计数再找第一个计数为 1 的）\\n    return -1\\n}",
      "tests": [
        {"call": "firstUniqChar(\\\"leetcode\\\")", "expect": "0"},
        {"call": "firstUniqChar(\\\"loveleetcode\\\")", "expect": "2"},
        {"call": "firstUniqChar(\\\"aabb\\\")", "expect": "-1"}
      ],
      "solution": "func firstUniqChar(s: String): Int64 {\\n    let b = s.toArray()\\n    let cnt = Array<Int64>(26, repeat: 0)\\n    for (c in b) {\\n        let k = Int64(c) - 97\\n        cnt[k] = cnt[k] + 1\\n    }\\n    for (i in 0..b.size) {\\n        if (cnt[Int64(b[i]) - 97] == 1) {\\n            return i\\n        }\\n    }\\n    return -1\\n}"
    },
    {
      "id": 46,
      "title": "反转字符串中的单词",
      "difficulty": "中等",
      "category": "字符串",
      "funcName": "reverseWords",
      "description": "给定一个字符串 s，按空格切分得到若干单词，返回单词顺序颠倒、单词之间用单个空格连接的字符串。开头结尾的空格与单词间的多余空格都要丢弃。",
      "template": "func reverseWords(s: String): String {\\n    // 请在这里实现算法（提示：按空格切词后倒序拼接）\\n    return \\\"\\\"\\n}",
      "tests": [
        {"call": "reverseWords(\\\"the sky is blue\\\")", "expect": "\\\"blue is sky the\\\""},
        {"call": "reverseWords(\\\"  hello world  \\\")", "expect": "\\\"world hello\\\""},
        {"call": "reverseWords(\\\"a good   example\\\")", "expect": "\\\"example good a\\\""}
      ],
      "solution": "func reverseWords(s: String): String {\\n    let words = ArrayList<String>()\\n    var buf = ArrayList<UInt8>()\\n    for (c in s.toArray()) {\\n        if (c == 32) {\\n            if (buf.size > 0) {\\n                words.add(String.fromUtf8(buf.toArray()))\\n                buf = ArrayList<UInt8>()\\n            }\\n        } else {\\n            buf.add(c)\\n        }\\n    }\\n    if (buf.size > 0) {\\n        words.add(String.fromUtf8(buf.toArray()))\\n    }\\n    var out = \\\"\\\"\\n    var i = words.size - 1\\n    while (i >= 0) {\\n        if (out.size > 0) {\\n            out = out + \\\" \\\"\\n        }\\n        out = out + words[i]\\n        i = i - 1\\n    }\\n    return out\\n}"
    },
    {
      "id": 47,
      "title": "字符串相加",
      "difficulty": "简单",
      "category": "字符串",
      "funcName": "addStrings",
      "description": "给定两个以字符串形式表示的非负整数 num1 与 num2，返回它们的和的字符串表示。不能使用内置的大整数类型。",
      "template": "func addStrings(num1: String, num2: String): String {\\n    // 请在这里实现算法（提示：模拟竖式，从个位起带进位）\\n    return \\\"\\\"\\n}",
      "tests": [
        {"call": "addStrings(\\\"11\\\", \\\"123\\\")", "expect": "\\\"134\\\""},
        {"call": "addStrings(\\\"456\\\", \\\"77\\\")", "expect": "\\\"533\\\""},
        {"call": "addStrings(\\\"0\\\", \\\"0\\\")", "expect": "\\\"0\\\""}
      ],
      "solution": "func addStrings(num1: String, num2: String): String {\\n    let a = num1.toArray()\\n    let b = num2.toArray()\\n    var i = a.size - 1\\n    var j = b.size - 1\\n    var carry: Int64 = 0\\n    let out = ArrayList<UInt8>()\\n    while (i >= 0 || j >= 0 || carry > 0) {\\n        var sum = carry\\n        if (i >= 0) {\\n            sum = sum + (Int64(a[i]) - 48)\\n            i = i - 1\\n        }\\n        if (j >= 0) {\\n            sum = sum + (Int64(b[j]) - 48)\\n            j = j - 1\\n        }\\n        out.add(UInt8(sum % 10) + 48)\\n        carry = sum / 10\\n    }\\n    var s = \\\"\\\"\\n    var k = out.size - 1\\n    while (k >= 0) {\\n        s = s + String.fromUtf8([out[k]])\\n        k = k - 1\\n    }\\n    return s\\n}"
    },
    {
      "id": 48,
      "title": "最长回文子串的长度",
      "difficulty": "中等",
      "category": "字符串",
      "funcName": "longestPalindromeLen",
      "description": "给定一个只含小写字母的字符串 s，返回它最长的回文子串的长度。",
      "template": "func longestPalindromeLen(s: String): Int64 {\\n    // 请在这里实现算法（提示：中心扩展，奇偶两种中心都试）\\n    return 0\\n}",
      "tests": [
        {"call": "longestPalindromeLen(\\\"babad\\\")", "expect": "3"},
        {"call": "longestPalindromeLen(\\\"cbbd\\\")", "expect": "2"},
        {"call": "longestPalindromeLen(\\\"a\\\")", "expect": "1"}
      ],
      "solution": "func expandFrom(b: Array<UInt8>, lo: Int64, hi: Int64): Int64 {\\n    var l = lo\\n    var r = hi\\n    while (l >= 0 && r < b.size && b[l] == b[r]) {\\n        l = l - 1\\n        r = r + 1\\n    }\\n    return r - l - 1\\n}\\n\\nfunc longestPalindromeLen(s: String): Int64 {\\n    let b = s.toArray()\\n    var best: Int64 = 0\\n    for (i in 0..b.size) {\\n        let a = expandFrom(b, i, i)\\n        let c = expandFrom(b, i, i + 1)\\n        if (a > best) {\\n            best = a\\n        }\\n        if (c > best) {\\n            best = c\\n        }\\n    }\\n    return best\\n}"
    },
    {
      "id": 49,
      "title": "外观数列",
      "difficulty": "中等",
      "category": "字符串",
      "funcName": "countAndSay",
      "description": "外观数列从 1 开始，每一项都是对前一项的读数（连续相同数字的个数加该数字）。给定正整数 n，返回这个数列的第 n 项。",
      "template": "func countAndSay(n: Int64): String {\\n    // 请在这里实现算法（提示：逐轮读上一项：个数 + 数字）\\n    return \\\"\\\"\\n}",
      "tests": [
        {"call": "countAndSay(1)", "expect": "\\\"1\\\""},
        {"call": "countAndSay(4)", "expect": "\\\"1211\\\""},
        {"call": "countAndSay(5)", "expect": "\\\"111221\\\""}
      ],
      "solution": "func countAndSay(n: Int64): String {\\n    var cur = \\\"1\\\"\\n    var round: Int64 = 1\\n    while (round < n) {\\n        let b = cur.toArray()\\n        var next = \\\"\\\"\\n        var i: Int64 = 0\\n        while (i < b.size) {\\n            var j = i\\n            while (j < b.size && b[j] == b[i]) {\\n                j = j + 1\\n            }\\n            next = next + String.fromUtf8([UInt8(48 + j - i)]) + String.fromUtf8([b[i]])\\n            i = j\\n        }\\n        cur = next\\n        round = round + 1\\n    }\\n    return cur\\n}"
    },
    {
      "id": 50,
      "title": "字符串转换整数",
      "difficulty": "中等",
      "category": "字符串",
      "funcName": "myAtoi",
      "description": "按规则把字符串转成 32 位有符号整数：跳过前导空白，读可选的符号，再读连续数字直到遇到非数字；没有读到数字返回 0；结果超出 32 位范围时截断到边界值。",
      "template": "func myAtoi(s: String): Int64 {\\n    // 请在这里实现算法（提示：跳空白、读符号、截断到 32 位范围）\\n    return 0\\n}",
      "tests": [
        {"call": "myAtoi(\\\"42\\\")", "expect": "42"},
        {"call": "myAtoi(\\\"   -42\\\")", "expect": "-42"},
        {"call": "myAtoi(\\\"4193 with words\\\")", "expect": "4193"},
        {"call": "myAtoi(\\\"words and 987\\\")", "expect": "0"}
      ],
      "solution": "func myAtoi(s: String): Int64 {\\n    let b = s.toArray()\\n    var i: Int64 = 0\\n    while (i < b.size && b[i] == 32) {\\n        i = i + 1\\n    }\\n    var sign: Int64 = 1\\n    if (i < b.size && (b[i] == 43 || b[i] == 45)) {\\n        if (b[i] == 45) {\\n            sign = -1\\n        }\\n        i = i + 1\\n    }\\n    var value: Int64 = 0\\n    while (i < b.size) {\\n        let c = b[i]\\n        if (c < 48 || c > 57) {\\n            break\\n        }\\n        value = value * 10 + (Int64(c) - 48)\\n        if (value > 2147483647) {\\n            break\\n        }\\n        i = i + 1\\n    }\\n    value = value * sign\\n    if (value > 2147483647) {\\n        return 2147483647\\n    }\\n    if (value < -2147483648) {\\n        return -2147483648\\n    }\\n    return value\\n}"
    },
    {
      "id": 51,
      "title": "单词长度的最大乘积",
      "difficulty": "中等",
      "category": "字符串",
      "funcName": "maxProduct",
      "description": "给定字符串数组 words，找出其中两个不含相同字母的单词，返回它们长度的乘积的最大值；不存在这样的两个单词则返回 0。单词只含小写字母。",
      "template": "func maxProduct(words: Array<String>): Int64 {\\n    // 请在这里实现算法（提示：位掩码表示字母集合再两两比较）\\n    return 0\\n}",
      "tests": [
        {"call": "maxProduct([\\\"abcw\\\", \\\"baz\\\", \\\"foo\\\", \\\"bar\\\", \\\"xtfn\\\", \\\"abcdef\\\"])", "expect": "16"},
        {"call": "maxProduct([\\\"a\\\", \\\"ab\\\", \\\"abc\\\", \\\"d\\\", \\\"cd\\\", \\\"bcd\\\", \\\"abcd\\\"])", "expect": "4"},
        {"call": "maxProduct([\\\"a\\\", \\\"aa\\\", \\\"aaa\\\", \\\"aaaa\\\"])", "expect": "0"}
      ],
      "solution": "func maxProduct(words: Array<String>): Int64 {\\n    let masks = ArrayList<Int64>()\\n    for (w in words) {\\n        var m: Int64 = 0\\n        for (c in w.toArray()) {\\n            var bit: Int64 = 1\\n            var k = Int64(c) - 97\\n            while (k > 0) {\\n                bit = bit * 2\\n                k = k - 1\\n            }\\n            if ((m & bit) == 0) {\\n                m = m + bit\\n            }\\n        }\\n        masks.add(m)\\n    }\\n    var best: Int64 = 0\\n    for (i in 0..words.size) {\\n        for (j in i + 1..words.size) {\\n            if ((masks[i] & masks[j]) == 0) {\\n                let p = words[i].toArray().size * words[j].toArray().size\\n                if (p > best) {\\n                    best = p\\n                }\\n            }\\n        }\\n    }\\n    return best\\n}"
    },
    {
      "id": 52,
      "title": "比较版本号",
      "difficulty": "中等",
      "category": "字符串",
      "funcName": "compareVersion",
      "description": "版本号由点分隔的数字段组成（段内可能有前导零）。比较两个版本号：前者的段更大返回 1，更小返回 -1，完全相同返回 0。段数不同时缺的段按 0 处理。",
      "template": "func compareVersion(v1: String, v2: String): Int64 {\\n    // 请在这里实现算法（提示：按点分段逐段比，缺段当 0）\\n    return 0\\n}",
      "tests": [
        {"call": "compareVersion(\\\"1.01\\\", \\\"1.001\\\")", "expect": "0"},
        {"call": "compareVersion(\\\"1.0\\\", \\\"1.0.0\\\")", "expect": "0"},
        {"call": "compareVersion(\\\"0.1\\\", \\\"1.1\\\")", "expect": "-1"},
        {"call": "compareVersion(\\\"1.0.1\\\", \\\"1\\\")", "expect": "1"}
      ],
      "solution": "func splitVersion(v: String): ArrayList<Int64> {\\n    let out = ArrayList<Int64>()\\n    var cur: Int64 = 0\\n    for (c in v.toArray()) {\\n        if (c == 46) {\\n            out.add(cur)\\n            cur = 0\\n        } else {\\n            cur = cur * 10 + (Int64(c) - 48)\\n        }\\n    }\\n    out.add(cur)\\n    return out\\n}\\n\\nfunc compareVersion(v1: String, v2: String): Int64 {\\n    let a = splitVersion(v1)\\n    let b = splitVersion(v2)\\n    var n = a.size\\n    if (b.size > n) {\\n        n = b.size\\n    }\\n    var i: Int64 = 0\\n    while (i < n) {\\n        var x: Int64 = 0\\n        var y: Int64 = 0\\n        if (i < a.size) {\\n            x = a[i]\\n        }\\n        if (i < b.size) {\\n            y = b[i]\\n        }\\n        if (x > y) {\\n            return 1\\n        }\\n        if (x < y) {\\n            return -1\\n        }\\n        i = i + 1\\n    }\\n    return 0\\n}"
    },
    {
      "id": 53,
      "title": "逆波兰表达式求值",
      "difficulty": "中等",
      "category": "栈与队列",
      "funcName": "evalRPN",
      "description": "给定用字符串数组表示的逆波兰表达式，运算符只有 + - * /（除法向零截断），返回表达式的值。",
      "template": "func evalRPN(tokens: Array<String>): Int64 {\\n    // 请在这里实现算法（提示：遇数入栈，遇运算符弹两个）\\n    return 0\\n}",
      "tests": [
        {"call": "evalRPN([\\\"2\\\", \\\"1\\\", \\\"+\\\", \\\"3\\\", \\\"*\\\"])", "expect": "9"},
        {"call": "evalRPN([\\\"4\\\", \\\"13\\\", \\\"5\\\", \\\"/\\\", \\\"+\\\"])", "expect": "6"},
        {"call": "evalRPN([\\\"10\\\", \\\"6\\\", \\\"9\\\", \\\"3\\\", \\\"+\\\", \\\"-11\\\", \\\"*\\\", \\\"/\\\", \\\"*\\\", \\\"17\\\", \\\"+\\\", \\\"5\\\", \\\"+\\\"])", "expect": "22"}
      ],
      "solution": "func parseIntToken(s: String): Int64 {\\n    let b = s.toArray()\\n    var i: Int64 = 0\\n    var sign: Int64 = 1\\n    if (b.size > 0 && b[0] == 45) {\\n        sign = -1\\n        i = 1\\n    }\\n    var v: Int64 = 0\\n    while (i < b.size) {\\n        v = v * 10 + (Int64(b[i]) - 48)\\n        i = i + 1\\n    }\\n    return v * sign\\n}\\n\\nfunc evalRPN(tokens: Array<String>): Int64 {\\n    let st = ArrayList<Int64>()\\n    for (t in tokens) {\\n        let b = t.toArray()\\n        let isOp = b.size == 1 && (b[0] == 43 || b[0] == 45 || b[0] == 42 || b[0] == 47)\\n        if (isOp) {\\n            let y = st[st.size - 1]\\n            st.remove(at: st.size - 1)\\n            let x = st[st.size - 1]\\n            st.remove(at: st.size - 1)\\n            var r: Int64 = 0\\n            if (b[0] == 43) {\\n                r = x + y\\n            } else if (b[0] == 45) {\\n                r = x - y\\n            } else if (b[0] == 42) {\\n                r = x * y\\n            } else {\\n                r = x / y\\n            }\\n            st.add(r)\\n        } else {\\n            st.add(parseIntToken(t))\\n        }\\n    }\\n    return st[0]\\n}"
    },
    {
      "id": 54,
      "title": "每日温度",
      "difficulty": "中等",
      "category": "栈与队列",
      "funcName": "dailyTemperatures",
      "description": "给定每日温度数组 temps，返回一个等长数组：第 i 位表示要等多少天才会出现比第 i 天更高的温度；若之后没有更高的温度则为 0。",
      "template": "func dailyTemperatures(temps: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：单调栈存下标）\\n    return []\\n}",
      "tests": [
        {"call": "dailyTemperatures([73, 74, 75, 71, 69, 72, 76, 73])", "expect": "[1, 1, 4, 2, 1, 1, 0, 0]"},
        {"call": "dailyTemperatures([30, 40, 50, 60])", "expect": "[1, 1, 1, 0]"},
        {"call": "dailyTemperatures([30, 60, 90])", "expect": "[1, 1, 0]"}
      ],
      "solution": "func dailyTemperatures(temps: Array<Int64>): Array<Int64> {\\n    let n = temps.size\\n    let out = Array<Int64>(n, repeat: 0)\\n    let st = ArrayList<Int64>()\\n    var i: Int64 = 0\\n    while (i < n) {\\n        while (st.size > 0 && temps[i] > temps[st[st.size - 1]]) {\\n            let k = st[st.size - 1]\\n            st.remove(at: st.size - 1)\\n            out[k] = i - k\\n        }\\n        st.add(i)\\n        i = i + 1\\n    }\\n    return out\\n}"
    },
    {
      "id": 55,
      "title": "用栈实现队列",
      "difficulty": "中等",
      "category": "栈与队列",
      "funcName": "queueByStack",
      "description": "用两个栈模拟一个队列，按操作序列 ops 执行并返回累加和。操作约定：op 大于 0 表示把 op 入队；op 等于 -1 表示出队并把出队值累加；op 等于 -2 表示取队首并把值累加（不出队）；op 等于 -3 表示判空（空累加 -1，非空累加 0）。",
      "template": "func queueByStack(ops: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：两个栈：入栈 + 出栈）\\n    return 0\\n}",
      "tests": [
        {"call": "queueByStack([1, 2, -1, -2, -1])", "expect": "5"},
        {"call": "queueByStack([-3, 5, -2, -3])", "expect": "4"},
        {"call": "queueByStack([7, -1, -3, -1])", "expect": "6"}
      ],
      "solution": "func queueByStack(ops: Array<Int64>): Int64 {\\n    let inStack = ArrayList<Int64>()\\n    let outStack = ArrayList<Int64>()\\n    var total: Int64 = 0\\n    for (op in ops) {\\n        if (op > 0) {\\n            inStack.add(op)\\n        } else if (op == -3) {\\n            if (inStack.size + outStack.size == 0) {\\n                total = total - 1\\n            }\\n        } else {\\n            if (outStack.size == 0) {\\n                while (inStack.size > 0) {\\n                    outStack.add(inStack[inStack.size - 1])\\n                    inStack.remove(at: inStack.size - 1)\\n                }\\n            }\\n            if (outStack.size > 0) {\\n                total = total + outStack[outStack.size - 1]\\n                if (op == -1) {\\n                    outStack.remove(at: outStack.size - 1)\\n                }\\n            }\\n        }\\n    }\\n    return total\\n}"
    },
    {
      "id": 56,
      "title": "删除字符串中的相邻重复项",
      "difficulty": "简单",
      "category": "栈与队列",
      "funcName": "removeAdjacentDuplicates",
      "description": "给定只含小写字母的字符串 s，反复删除相邻且相同的字符对，直到无法继续删除，返回最终字符串。",
      "template": "func removeAdjacentDuplicates(s: String): String {\\n    // 请在这里实现算法（提示：栈消消乐）\\n    return \\\"\\\"\\n}",
      "tests": [
        {"call": "removeAdjacentDuplicates(\\\"abbaca\\\")", "expect": "\\\"ca\\\""},
        {"call": "removeAdjacentDuplicates(\\\"azxxzy\\\")", "expect": "\\\"ay\\\""},
        {"call": "removeAdjacentDuplicates(\\\"a\\\")", "expect": "\\\"a\\\""}
      ],
      "solution": "func removeAdjacentDuplicates(s: String): String {\\n    let st = ArrayList<UInt8>()\\n    for (c in s.toArray()) {\\n        if (st.size > 0 && st[st.size - 1] == c) {\\n            st.remove(at: st.size - 1)\\n        } else {\\n            st.add(c)\\n        }\\n    }\\n    return String.fromUtf8(st.toArray())\\n}"
    },
    {
      "id": 57,
      "title": "字符串解码的长度",
      "difficulty": "中等",
      "category": "栈与队列",
      "funcName": "decodeStringLen",
      "description": "给定形如 3[a]2[bc] 的编码字符串（数字加方括号表示括号内内容重复多少次，可以嵌套），返回解码后字符串的长度。",
      "template": "func decodeStringLen(s: String): Int64 {\\n    // 请在这里实现算法（提示：栈存倍数与已解出的长度）\\n    return 0\\n}",
      "tests": [
        {"call": "decodeStringLen(\\\"3[a]2[bc]\\\")", "expect": "7"},
        {"call": "decodeStringLen(\\\"3[a2[c]]\\\")", "expect": "9"},
        {"call": "decodeStringLen(\\\"2[abc]3[cd]ef\\\")", "expect": "14"}
      ],
      "solution": "func decodeStringLen(s: String): Int64 {\\n    let reps = ArrayList<Int64>()\\n    let bases = ArrayList<Int64>()\\n    var cur: Int64 = 0\\n    var num: Int64 = 0\\n    for (c in s.toArray()) {\\n        if (c >= 48 && c <= 57) {\\n            num = num * 10 + (Int64(c) - 48)\\n        } else if (c == 91) {\\n            reps.add(num)\\n            bases.add(cur)\\n            num = 0\\n            cur = 0\\n        } else if (c == 93) {\\n            let rep = reps[reps.size - 1]\\n            reps.remove(at: reps.size - 1)\\n            let base = bases[bases.size - 1]\\n            bases.remove(at: bases.size - 1)\\n            cur = base + rep * cur\\n        } else {\\n            cur = cur + 1\\n        }\\n    }\\n    return cur\\n}"
    },
    {
      "id": 58,
      "title": "柱状图中最大的矩形",
      "difficulty": "困难",
      "category": "栈与队列",
      "funcName": "largestRectangleArea",
      "description": "给定表示柱状图每根柱子高度的数组 heights，返回其中能勾勒出的最大矩形面积（每根柱子宽度为 1）。",
      "template": "func largestRectangleArea(heights: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：单调递增栈 + 末尾哨兵）\\n    return 0\\n}",
      "tests": [
        {"call": "largestRectangleArea([2, 1, 5, 6, 2, 3])", "expect": "10"},
        {"call": "largestRectangleArea([2, 4])", "expect": "4"},
        {"call": "largestRectangleArea([1])", "expect": "1"}
      ],
      "solution": "func largestRectangleArea(heights: Array<Int64>): Int64 {\\n    let st = ArrayList<Int64>()\\n    var best: Int64 = 0\\n    var i: Int64 = 0\\n    while (i <= heights.size) {\\n        var h: Int64 = 0\\n        if (i < heights.size) {\\n            h = heights[i]\\n        }\\n        while (st.size > 0 && heights[st[st.size - 1]] >= h) {\\n            let top = st[st.size - 1]\\n            st.remove(at: st.size - 1)\\n            var left: Int64 = -1\\n            if (st.size > 0) {\\n                left = st[st.size - 1]\\n            }\\n            let area = heights[top] * (i - left - 1)\\n            if (area > best) {\\n                best = area\\n            }\\n        }\\n        st.add(i)\\n        i = i + 1\\n    }\\n    return best\\n}"
    },
    {
      "id": 59,
      "title": "简化路径",
      "difficulty": "中等",
      "category": "栈与队列",
      "funcName": "simplifyPath",
      "description": "把 Unix 风格的绝对路径简化为规范形式：多个连续斜杠合并为一个，. 表示当前目录直接忽略，.. 表示上级目录（若已在根目录则忽略），结果以斜杠开头且不以斜杠结尾。",
      "template": "func simplifyPath(path: String): String {\\n    // 请在这里实现算法（提示：按斜杠切分后处理点）\\n    return \\\"\\\"\\n}",
      "tests": [
        {"call": "simplifyPath(\\\"/home/\\\")", "expect": "\\\"/home\\\""},
        {"call": "simplifyPath(\\\"/../\\\")", "expect": "\\\"/\\\""},
        {"call": "simplifyPath(\\\"/home//foo/\\\")", "expect": "\\\"/home/foo\\\""}
      ],
      "solution": "func simplifyPath(path: String): String {\\n    let parts = ArrayList<String>()\\n    var buf = ArrayList<UInt8>()\\n    for (c in path.toArray()) {\\n        if (c == 47) {\\n            parts.add(String.fromUtf8(buf.toArray()))\\n            buf = ArrayList<UInt8>()\\n        } else {\\n            buf.add(c)\\n        }\\n    }\\n    parts.add(String.fromUtf8(buf.toArray()))\\n    let st = ArrayList<String>()\\n    for (p in parts) {\\n        if (p.size == 0 || p == \\\".\\\") {\\n            continue\\n        }\\n        if (p == \\\"..\\\") {\\n            if (st.size > 0) {\\n                st.remove(at: st.size - 1)\\n            }\\n        } else {\\n            st.add(p)\\n        }\\n    }\\n    var out = \\\"\\\"\\n    for (p in st) {\\n        out = out + \\\"/\\\" + p\\n    }\\n    if (out.size == 0) {\\n        return \\\"/\\\"\\n    }\\n    return out\\n}"
    },
    {
      "id": 60,
      "title": "反转链表",
      "difficulty": "简单",
      "category": "链表",
      "funcName": "reverseList",
      "description": "链表用数组表示：head 中元素的先后顺序就是链表的结点顺序。返回反转后的链表（同样用数组表示）。",
      "template": "func reverseList(head: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：数组按下标倒着取）\\n    return []\\n}",
      "tests": [
        {"call": "reverseList([1, 2, 3, 4, 5])", "expect": "[5, 4, 3, 2, 1]"},
        {"call": "reverseList([1, 2])", "expect": "[2, 1]"},
        {"call": "reverseList([])", "expect": "[]"}
      ],
      "solution": "func reverseList(head: Array<Int64>): Array<Int64> {\\n    let n = head.size\\n    let out = Array<Int64>(n, repeat: 0)\\n    var i: Int64 = 0\\n    while (i < n) {\\n        out[i] = head[n - 1 - i]\\n        i = i + 1\\n    }\\n    return out\\n}"
    },
    {
      "id": 61,
      "title": "合并两个有序链表",
      "difficulty": "简单",
      "category": "链表",
      "funcName": "mergeTwoLists",
      "description": "两个链表用升序数组表示，把它们合并为一个新的升序链表（用数组表示），按结点值从小到大排列。",
      "template": "func mergeTwoLists(a: Array<Int64>, b: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：双指针归并）\\n    return []\\n}",
      "tests": [
        {"call": "mergeTwoLists([1, 2, 4], [1, 3, 4])", "expect": "[1, 1, 2, 3, 4, 4]"},
        {"call": "mergeTwoLists([], [])", "expect": "[]"},
        {"call": "mergeTwoLists([], [0])", "expect": "[0]"}
      ],
      "solution": "func mergeTwoLists(a: Array<Int64>, b: Array<Int64>): Array<Int64> {\\n    let out = ArrayList<Int64>()\\n    var i: Int64 = 0\\n    var j: Int64 = 0\\n    while (i < a.size && j < b.size) {\\n        if (a[i] <= b[j]) {\\n            out.add(a[i])\\n            i = i + 1\\n        } else {\\n            out.add(b[j])\\n            j = j + 1\\n        }\\n    }\\n    while (i < a.size) {\\n        out.add(a[i])\\n        i = i + 1\\n    }\\n    while (j < b.size) {\\n        out.add(b[j])\\n        j = j + 1\\n    }\\n    return out.toArray()\\n}"
    },
    {
      "id": 62,
      "title": "删除链表的倒数第 N 个结点",
      "difficulty": "中等",
      "category": "链表",
      "funcName": "removeNthFromEnd",
      "description": "链表用数组 head 表示。删除链表中倒数第 n 个结点，返回删除后的链表（用数组表示）。n 保证有效。",
      "template": "func removeNthFromEnd(head: Array<Int64>, n: Int64): Array<Int64> {\\n    // 请在这里实现算法（提示：先算出要删的下标）\\n    return []\\n}",
      "tests": [
        {"call": "removeNthFromEnd([1, 2, 3, 4, 5], 2)", "expect": "[1, 2, 3, 5]"},
        {"call": "removeNthFromEnd([1], 1)", "expect": "[]"},
        {"call": "removeNthFromEnd([1, 2], 1)", "expect": "[1]"}
      ],
      "solution": "func removeNthFromEnd(head: Array<Int64>, n: Int64): Array<Int64> {\\n    let skip = head.size - n\\n    let out = ArrayList<Int64>()\\n    for (i in 0..head.size) {\\n        if (i != skip) {\\n            out.add(head[i])\\n        }\\n    }\\n    return out.toArray()\\n}"
    },
    {
      "id": 63,
      "title": "链表的中间结点",
      "difficulty": "简单",
      "category": "链表",
      "funcName": "middleNode",
      "description": "链表用数组 head 表示。返回链表的中间结点及其之后的所有结点：中间结点取下标 size 除 2 向下取整（偶数个结点时取后一个中间结点）。",
      "template": "func middleNode(head: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：快慢指针（下标步长 1 与 2））\\n    return []\\n}",
      "tests": [
        {"call": "middleNode([1, 2, 3, 4, 5])", "expect": "[3, 4, 5]"},
        {"call": "middleNode([1, 2, 3, 4])", "expect": "[3, 4]"},
        {"call": "middleNode([1])", "expect": "[1]"}
      ],
      "solution": "func middleNode(head: Array<Int64>): Array<Int64> {\\n    let mid = head.size / 2\\n    let out = ArrayList<Int64>()\\n    var i = mid\\n    while (i < head.size) {\\n        out.add(head[i])\\n        i = i + 1\\n    }\\n    return out.toArray()\\n}"
    },
    {
      "id": 64,
      "title": "环形链表",
      "difficulty": "简单",
      "category": "链表",
      "funcName": "hasCycle",
      "description": "链表用数组 values 表示结点值：最后一个结点指向下标 pos 处的结点（pos 为 -1 表示没有环）。判断链表中是否存在环。",
      "template": "func hasCycle(values: Array<Int64>, pos: Int64): Bool {\\n    // 请在这里实现算法（提示：快慢指针（下标即指针））\\n    return false\\n}",
      "tests": [
        {"call": "hasCycle([3, 2, 0, -4], 1)", "expect": "true"},
        {"call": "hasCycle([1, 2], -1)", "expect": "false"},
        {"call": "hasCycle([1], -1)", "expect": "false"},
        {"call": "hasCycle([1, 2, 3], 0)", "expect": "true"}
      ],
      "solution": "func nextNode(i: Int64, n: Int64, pos: Int64): Int64 {\\n    if (i < n - 1) {\\n        return i + 1\\n    }\\n    return pos\\n}\\n\\nfunc hasCycle(values: Array<Int64>, pos: Int64): Bool {\\n    let n = values.size\\n    if (n == 0) {\\n        return false\\n    }\\n    var slow: Int64 = 0\\n    var fast: Int64 = 0\\n    var guard: Int64 = 0\\n    while (guard <= n + 1) {\\n        slow = nextNode(slow, n, pos)\\n        fast = nextNode(fast, n, pos)\\n        if (fast < 0) {\\n            return false\\n        }\\n        fast = nextNode(fast, n, pos)\\n        if (fast < 0) {\\n            return false\\n        }\\n        if (slow == fast) {\\n            return true\\n        }\\n        guard = guard + 1\\n    }\\n    return true\\n}"
    },
    {
      "id": 65,
      "title": "回文链表",
      "difficulty": "简单",
      "category": "链表",
      "funcName": "isPalindromeList",
      "description": "链表用数组 head 表示，判断它的结点序列是否是回文。",
      "template": "func isPalindromeList(head: Array<Int64>): Bool {\\n    // 请在这里实现算法（提示：数组双指针）\\n    return false\\n}",
      "tests": [
        {"call": "isPalindromeList([1, 2, 2, 1])", "expect": "true"},
        {"call": "isPalindromeList([1, 2])", "expect": "false"},
        {"call": "isPalindromeList([1])", "expect": "true"}
      ],
      "solution": "func isPalindromeList(head: Array<Int64>): Bool {\\n    var i: Int64 = 0\\n    var j = head.size - 1\\n    while (i < j) {\\n        if (head[i] != head[j]) {\\n            return false\\n        }\\n        i = i + 1\\n        j = j - 1\\n    }\\n    return true\\n}"
    },
    {
      "id": 66,
      "title": "二叉树的最大深度",
      "difficulty": "简单",
      "category": "二叉树",
      "funcName": "maxDepth",
      "description": "二叉树按层序（广度优先）遍历用数组给出：下标 i 处结点的左右孩子分别在下标 2i+1 与 2i+2。-1 表示该位置没有结点，结点值均为非负整数。返回树的最大深度（根所在层深度为 1，空树为 0）。",
      "template": "func maxDepth(level: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：按层序数组递归求深）\\n    return 0\\n}",
      "tests": [
        {"call": "maxDepth([3, 9, 20, -1, -1, 15, 7])", "expect": "3"},
        {"call": "maxDepth([1, -1, 2])", "expect": "2"},
        {"call": "maxDepth([])", "expect": "0"}
      ],
      "solution": "func depthAt(a: Array<Int64>, i: Int64): Int64 {\\n    if (i >= a.size || a[i] < 0) {\\n        return 0\\n    }\\n    let l = depthAt(a, i * 2 + 1)\\n    let r = depthAt(a, i * 2 + 2)\\n    if (l > r) {\\n        return l + 1\\n    }\\n    return r + 1\\n}\\n\\nfunc maxDepth(level: Array<Int64>): Int64 {\\n    return depthAt(level, 0)\\n}"
    },
    {
      "id": 67,
      "title": "对称二叉树",
      "difficulty": "简单",
      "category": "二叉树",
      "funcName": "isSymmetric",
      "description": "二叉树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。判断这棵树是否轴对称。",
      "template": "func isSymmetric(level: Array<Int64>): Bool {\\n    // 请在这里实现算法（提示：镜像比较左右子树）\\n    return true\\n}",
      "tests": [
        {"call": "isSymmetric([1, 2, 2, 3, 4, 4, 3])", "expect": "true"},
        {"call": "isSymmetric([1, 2, 2, -1, 3, -1, 3])", "expect": "false"},
        {"call": "isSymmetric([1])", "expect": "true"}
      ],
      "solution": "func mirrorPair(a: Array<Int64>, i: Int64, j: Int64): Bool {\\n    let ei = i >= a.size || a[i] < 0\\n    let ej = j >= a.size || a[j] < 0\\n    if (ei && ej) {\\n        return true\\n    }\\n    if (ei || ej) {\\n        return false\\n    }\\n    if (a[i] != a[j]) {\\n        return false\\n    }\\n    return mirrorPair(a, i * 2 + 1, j * 2 + 2) && mirrorPair(a, i * 2 + 2, j * 2 + 1)\\n}\\n\\nfunc isSymmetric(level: Array<Int64>): Bool {\\n    if (level.size == 0 || level[0] < 0) {\\n        return true\\n    }\\n    return mirrorPair(level, 0, 0)\\n}"
    },
    {
      "id": 68,
      "title": "二叉树的中序遍历",
      "difficulty": "中等",
      "category": "二叉树",
      "funcName": "inorderTraversal",
      "description": "二叉树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。返回它的中序遍历序列。",
      "template": "func inorderTraversal(level: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：中序递归：左 - 根 - 右）\\n    return []\\n}",
      "tests": [
        {"call": "inorderTraversal([1, 2, 3])", "expect": "[2, 1, 3]"},
        {"call": "inorderTraversal([1, 2, 3, 4, 5, 6, 7])", "expect": "[4, 2, 5, 1, 6, 3, 7]"},
        {"call": "inorderTraversal([])", "expect": "[]"}
      ],
      "solution": "func inorderAt(a: Array<Int64>, i: Int64, out: ArrayList<Int64>): Unit {\\n    if (i >= a.size || a[i] < 0) {\\n        return\\n    }\\n    inorderAt(a, i * 2 + 1, out)\\n    out.add(a[i])\\n    inorderAt(a, i * 2 + 2, out)\\n}\\n\\nfunc inorderTraversal(level: Array<Int64>): Array<Int64> {\\n    let out = ArrayList<Int64>()\\n    inorderAt(level, 0, out)\\n    return out.toArray()\\n}"
    },
    {
      "id": 69,
      "title": "二叉树的层结点数",
      "difficulty": "中等",
      "category": "二叉树",
      "funcName": "levelNodeCounts",
      "description": "二叉树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。返回一棵数组：第 k 项是第 k 层实际存在的结点个数（根所在层是第 1 项）。",
      "template": "func levelNodeCounts(level: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：按下标区间统计每层结点数）\\n    return []\\n}",
      "tests": [
        {"call": "levelNodeCounts([3, 9, 20, -1, -1, 15, 7])", "expect": "[1, 2, 2]"},
        {"call": "levelNodeCounts([1, 2, 3, 4, 5, 6, 7])", "expect": "[1, 2, 4]"},
        {"call": "levelNodeCounts([])", "expect": "[]"}
      ],
      "solution": "func levelNodeCounts(level: Array<Int64>): Array<Int64> {\\n    let out = ArrayList<Int64>()\\n    var start: Int64 = 0\\n    var width: Int64 = 1\\n    while (start < level.size) {\\n        var count: Int64 = 0\\n        var k = start\\n        while (k < start + width && k < level.size) {\\n            if (level[k] >= 0) {\\n                count = count + 1\\n            }\\n            k = k + 1\\n        }\\n        out.add(count)\\n        start = start + width\\n        width = width * 2\\n    }\\n    return out.toArray()\\n}"
    },
    {
      "id": 70,
      "title": "路径总和",
      "difficulty": "简单",
      "category": "二叉树",
      "funcName": "hasPathSum",
      "description": "二叉树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。判断是否存在一条从根结点到叶子结点的路径，使路径上所有结点值之和等于 targetSum。",
      "template": "func hasPathSum(level: Array<Int64>, targetSum: Int64): Bool {\\n    // 请在这里实现算法（提示：递归累减到叶子）\\n    return false\\n}",
      "tests": [
        {"call": "hasPathSum([5, 4, 8, 11, -1, 13, 4, 7, 2, -1, -1, -1, 1], 22)", "expect": "true"},
        {"call": "hasPathSum([1, 2, 3], 5)", "expect": "false"},
        {"call": "hasPathSum([1, 2], 3)", "expect": "true"}
      ],
      "solution": "func hasSumAt(a: Array<Int64>, i: Int64, rest: Int64): Bool {\\n    if (i >= a.size || a[i] < 0) {\\n        return false\\n    }\\n    let left = i * 2 + 1\\n    let right = i * 2 + 2\\n    let leftEmpty = left >= a.size || a[left] < 0\\n    let rightEmpty = right >= a.size || a[right] < 0\\n    if (leftEmpty && rightEmpty) {\\n        return rest == a[i]\\n    }\\n    let next = rest - a[i]\\n    return hasSumAt(a, left, next) || hasSumAt(a, right, next)\\n}\\n\\nfunc hasPathSum(level: Array<Int64>, targetSum: Int64): Bool {\\n    return hasSumAt(level, 0, targetSum)\\n}"
    },
    {
      "id": 71,
      "title": "二叉树的直径",
      "difficulty": "简单",
      "category": "二叉树",
      "funcName": "diameterOfBinaryTree",
      "description": "二叉树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。返回树的直径：任意两个结点之间最长路径的边数。",
      "template": "func diameterOfBinaryTree(level: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：后序返回 (子树高度, 已知最大直径)）\\n    return 0\\n}",
      "tests": [
        {"call": "diameterOfBinaryTree([1, 2, 3, 4, 5])", "expect": "3"},
        {"call": "diameterOfBinaryTree([1, 2])", "expect": "1"},
        {"call": "diameterOfBinaryTree([1])", "expect": "0"}
      ],
      "solution": "func diaAt(a: Array<Int64>, i: Int64): (Int64, Int64) {\\n    if (i >= a.size || a[i] < 0) {\\n        return (0, 0)\\n    }\\n    let l = diaAt(a, i * 2 + 1)\\n    let r = diaAt(a, i * 2 + 2)\\n    let lh = l[0]\\n    let rh = r[0]\\n    var best = l[1]\\n    if (r[1] > best) {\\n        best = r[1]\\n    }\\n    let through = lh + rh\\n    if (through > best) {\\n        best = through\\n    }\\n    var h = lh\\n    if (rh > h) {\\n        h = rh\\n    }\\n    return (h + 1, best)\\n}\\n\\nfunc diameterOfBinaryTree(level: Array<Int64>): Int64 {\\n    let r = diaAt(level, 0)\\n    return r[1]\\n}"
    },
    {
      "id": 72,
      "title": "翻转二叉树",
      "difficulty": "简单",
      "category": "二叉树",
      "funcName": "invertTree",
      "description": "二叉树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。把每个结点的左右子树互换，返回翻转后的层序数组（长度与原数组一致，空位仍为 -1）。",
      "template": "func invertTree(level: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：把左右子树按下标镜像搬过去）\\n    return []\\n}",
      "tests": [
        {"call": "invertTree([4, 2, 7, 1, 3, 6, 9])", "expect": "[4, 7, 2, 9, 6, 3, 1]"},
        {"call": "invertTree([2, 1, 3])", "expect": "[2, 3, 1]"},
        {"call": "invertTree([])", "expect": "[]"}
      ],
      "solution": "func mirrorAt(a: Array<Int64>, src: Int64, dst: Int64, out: Array<Int64>): Unit {\\n    if (src >= a.size || a[src] < 0) {\\n        return\\n    }\\n    out[dst] = a[src]\\n    mirrorAt(a, src * 2 + 1, dst * 2 + 2, out)\\n    mirrorAt(a, src * 2 + 2, dst * 2 + 1, out)\\n}\\n\\nfunc invertTree(level: Array<Int64>): Array<Int64> {\\n    let out = Array<Int64>(level.size, repeat: -1)\\n    mirrorAt(level, 0, 0, out)\\n    return out\\n}"
    },
    {
      "id": 73,
      "title": "二叉搜索树中的搜索",
      "difficulty": "简单",
      "category": "二叉树",
      "funcName": "searchBST",
      "description": "二叉搜索树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。判断树中是否存在值为 target 的结点。",
      "template": "func searchBST(level: Array<Int64>, target: Int64): Bool {\\n    // 请在这里实现算法（提示：利用左小右大逐层下探）\\n    return false\\n}",
      "tests": [
        {"call": "searchBST([4, 2, 7, 1, 3], 2)", "expect": "true"},
        {"call": "searchBST([4, 2, 7, 1, 3], 5)", "expect": "false"},
        {"call": "searchBST([], 1)", "expect": "false"}
      ],
      "solution": "func searchBST(level: Array<Int64>, target: Int64): Bool {\\n    var i: Int64 = 0\\n    while (i < level.size && level[i] >= 0) {\\n        if (level[i] == target) {\\n            return true\\n        }\\n        if (target < level[i]) {\\n            i = i * 2 + 1\\n        } else {\\n            i = i * 2 + 2\\n        }\\n    }\\n    return false\\n}"
    },
    {
      "id": 74,
      "title": "验证二叉搜索树",
      "difficulty": "中等",
      "category": "二叉树",
      "funcName": "isValidBST",
      "description": "二叉树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。判断它是否是二叉搜索树（左子树所有结点值小于根，右子树所有结点值大于根）。",
      "template": "func isValidBST(level: Array<Int64>): Bool {\\n    // 请在这里实现算法（提示：中序序列必须严格递增）\\n    return true\\n}",
      "tests": [
        {"call": "isValidBST([2, 1, 3])", "expect": "true"},
        {"call": "isValidBST([5, 1, 4, -1, -1, 3, 6])", "expect": "false"},
        {"call": "isValidBST([1])", "expect": "true"}
      ],
      "solution": "func inorderAt(a: Array<Int64>, i: Int64, out: ArrayList<Int64>): Unit {\\n    if (i >= a.size || a[i] < 0) {\\n        return\\n    }\\n    inorderAt(a, i * 2 + 1, out)\\n    out.add(a[i])\\n    inorderAt(a, i * 2 + 2, out)\\n}\\n\\nfunc isValidBST(level: Array<Int64>): Bool {\\n    let seq = ArrayList<Int64>()\\n    inorderAt(level, 0, seq)\\n    var i: Int64 = 1\\n    while (i < seq.size) {\\n        if (seq[i] <= seq[i - 1]) {\\n            return false\\n        }\\n        i = i + 1\\n    }\\n    return true\\n}"
    },
    {
      "id": 75,
      "title": "二叉搜索树中第 K 小的元素",
      "difficulty": "中等",
      "category": "二叉树",
      "funcName": "kthSmallest",
      "description": "二叉搜索树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。返回树中第 k 小的结点值（k 从 1 开始，保证有效）。",
      "template": "func kthSmallest(level: Array<Int64>, k: Int64): Int64 {\\n    // 请在这里实现算法（提示：中序遍历取第 k 个）\\n    return 0\\n}",
      "tests": [
        {"call": "kthSmallest([3, 1, 4, -1, 2], 1)", "expect": "1"},
        {"call": "kthSmallest([5, 3, 6, 2, 4, -1, -1, 1], 3)", "expect": "3"},
        {"call": "kthSmallest([1], 1)", "expect": "1"}
      ],
      "solution": "func inorderAt(a: Array<Int64>, i: Int64, out: ArrayList<Int64>): Unit {\\n    if (i >= a.size || a[i] < 0) {\\n        return\\n    }\\n    inorderAt(a, i * 2 + 1, out)\\n    out.add(a[i])\\n    inorderAt(a, i * 2 + 2, out)\\n}\\n\\nfunc kthSmallest(level: Array<Int64>, k: Int64): Int64 {\\n    let seq = ArrayList<Int64>()\\n    inorderAt(level, 0, seq)\\n    return seq[k - 1]\\n}"
    },
    {
      "id": 76,
      "title": "二叉树的最近公共祖先",
      "difficulty": "中等",
      "category": "二叉树",
      "funcName": "lowestCommonAncestor",
      "description": "二叉树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。结点值互不相同，p 与 q 是树中存在的两个结点值。返回它们的最近公共祖先的结点值。",
      "template": "func lowestCommonAncestor(level: Array<Int64>, p: Int64, q: Int64): Int64 {\\n    // 请在这里实现算法（提示：后序：左右都找到时当前结点即答案）\\n    return 0\\n}",
      "tests": [
        {"call": "lowestCommonAncestor([3, 5, 1, 6, 2, 0, 8, -1, -1, 7, 4], 5, 1)", "expect": "3"},
        {"call": "lowestCommonAncestor([3, 5, 1, 6, 2, 0, 8, -1, -1, 7, 4], 5, 4)", "expect": "5"},
        {"call": "lowestCommonAncestor([1, 2], 1, 2)", "expect": "1"}
      ],
      "solution": "func lcaAt(a: Array<Int64>, i: Int64, p: Int64, q: Int64): Int64 {\\n    if (i >= a.size || a[i] < 0) {\\n        return -1\\n    }\\n    if (a[i] == p || a[i] == q) {\\n        return i\\n    }\\n    let l = lcaAt(a, i * 2 + 1, p, q)\\n    let r = lcaAt(a, i * 2 + 2, p, q)\\n    if (l >= 0 && r >= 0) {\\n        return i\\n    }\\n    if (l >= 0) {\\n        return l\\n    }\\n    return r\\n}\\n\\nfunc lowestCommonAncestor(level: Array<Int64>, p: Int64, q: Int64): Int64 {\\n    let idx = lcaAt(level, 0, p, q)\\n    return level[idx]\\n}"
    },
    {
      "id": 77,
      "title": "从前序与中序构造二叉树的后序",
      "difficulty": "中等",
      "category": "二叉树",
      "funcName": "buildTreePostorder",
      "description": "给定一棵二叉树的前序遍历序列 preorder 与中序遍历序列 inorder（结点值互不相同），返回它的后序遍历序列。",
      "template": "func buildTreePostorder(preorder: Array<Int64>, inorder: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：按区间递归切分左右子树）\\n    return []\\n}",
      "tests": [
        {"call": "buildTreePostorder([3, 9, 20, 15, 7], [9, 3, 15, 20, 7])", "expect": "[9, 15, 7, 20, 3]"},
        {"call": "buildTreePostorder([1, 2], [2, 1])", "expect": "[2, 1]"},
        {"call": "buildTreePostorder([], [])", "expect": "[]"}
      ],
      "solution": "func postFromPreIn(pre: Array<Int64>, ino: Array<Int64>, ps: Int64, pe: Int64, ls: Int64, le: Int64, out: ArrayList<Int64>): Unit {\\n    if (ps > pe || ls > le) {\\n        return\\n    }\\n    let root = pre[ps]\\n    var mid = ls\\n    while (mid <= le && ino[mid] != root) {\\n        mid = mid + 1\\n    }\\n    let leftLen = mid - ls\\n    postFromPreIn(pre, ino, ps + 1, ps + leftLen, ls, mid - 1, out)\\n    postFromPreIn(pre, ino, ps + leftLen + 1, pe, mid + 1, le, out)\\n    out.add(root)\\n}\\n\\nfunc buildTreePostorder(preorder: Array<Int64>, inorder: Array<Int64>): Array<Int64> {\\n    let out = ArrayList<Int64>()\\n    postFromPreIn(preorder, inorder, 0, preorder.size - 1, 0, inorder.size - 1, out)\\n    return out.toArray()\\n}"
    },
    {
      "id": 78,
      "title": "二叉树的右视图",
      "difficulty": "中等",
      "category": "二叉树",
      "funcName": "rightSideView",
      "description": "二叉树按层序数组给出（下标 i 的孩子在 2i+1 与 2i+2，-1 表示空位）。返回从右侧能看到的结点值：每层最右边那个结点的值，按层从上到下排列。",
      "template": "func rightSideView(level: Array<Int64>): Array<Int64> {\\n    // 请在这里实现算法（提示：每层取最右侧的结点）\\n    return []\\n}",
      "tests": [
        {"call": "rightSideView([1, 2, 3, -1, 5, -1, 4])", "expect": "[1, 3, 4]"},
        {"call": "rightSideView([1, -1, 3])", "expect": "[1, 3]"},
        {"call": "rightSideView([])", "expect": "[]"}
      ],
      "solution": "func rightSideView(level: Array<Int64>): Array<Int64> {\\n    let out = ArrayList<Int64>()\\n    var start: Int64 = 0\\n    var width: Int64 = 1\\n    while (start < level.size) {\\n        var pick: Int64 = -1\\n        var k = start\\n        while (k < start + width && k < level.size) {\\n            if (level[k] >= 0) {\\n                pick = k\\n            }\\n            k = k + 1\\n        }\\n        if (pick >= 0) {\\n            out.add(level[pick])\\n        }\\n        start = start + width\\n        width = width * 2\\n    }\\n    return out.toArray()\\n}"
    },
    {
      "id": 79,
      "title": "分割回文串的个数",
      "difficulty": "中等",
      "category": "递归与回溯",
      "funcName": "countPalindromePartitions",
      "description": "给定字符串 s，统计有多少种方式把它分割成若干个连续的子串，使每个子串都是回文串。",
      "template": "func countPalindromePartitions(s: String): Int64 {\\n    // 请在这里实现算法（提示：按回文前缀切分后回溯）\\n    return 0\\n}",
      "tests": [
        {"call": "countPalindromePartitions(\\\"aab\\\")", "expect": "2"},
        {"call": "countPalindromePartitions(\\\"a\\\")", "expect": "1"},
        {"call": "countPalindromePartitions(\\\"aba\\\")", "expect": "2"}
      ],
      "solution": "func palCheck(b: Array<UInt8>, lo: Int64, hi: Int64): Bool {\\n    var i = lo\\n    var j = hi\\n    while (i < j) {\\n        if (b[i] != b[j]) {\\n            return false\\n        }\\n        i = i + 1\\n        j = j - 1\\n    }\\n    return true\\n}\\n\\nfunc partFrom(b: Array<UInt8>, start: Int64): Int64 {\\n    if (start == b.size) {\\n        return 1\\n    }\\n    var total: Int64 = 0\\n    var end = start\\n    while (end < b.size) {\\n        if (palCheck(b, start, end)) {\\n            total = total + partFrom(b, end + 1)\\n        }\\n        end = end + 1\\n    }\\n    return total\\n}\\n\\nfunc countPalindromePartitions(s: String): Int64 {\\n    return partFrom(s.toArray(), 0)\\n}"
    },
    {
      "id": 80,
      "title": "N 皇后",
      "difficulty": "困难",
      "category": "递归与回溯",
      "funcName": "countNQueens",
      "description": "在 n×n 的棋盘上放置 n 个皇后，使它们互不攻击（同一行、同一列、同一条斜线上只能有一个），返回所有不同摆法的个数。",
      "template": "func countNQueens(n: Int64): Int64 {\\n    // 请在这里实现算法（提示：逐行放皇后，列与两条斜线打表）\\n    return 0\\n}",
      "tests": [
        {"call": "countNQueens(4)", "expect": "2"},
        {"call": "countNQueens(1)", "expect": "1"},
        {"call": "countNQueens(6)", "expect": "4"}
      ],
      "solution": "func queenTry(row: Int64, n: Int64, cols: Array<Bool>, d1: Array<Bool>, d2: Array<Bool>): Int64 {\\n    if (row == n) {\\n        return 1\\n    }\\n    var total: Int64 = 0\\n    var c: Int64 = 0\\n    while (c < n) {\\n        let a = row + c\\n        let b = row - c + n\\n        if (!cols[c] && !d1[a] && !d2[b]) {\\n            cols[c] = true\\n            d1[a] = true\\n            d2[b] = true\\n            total = total + queenTry(row + 1, n, cols, d1, d2)\\n            cols[c] = false\\n            d1[a] = false\\n            d2[b] = false\\n        }\\n        c = c + 1\\n    }\\n    return total\\n}\\n\\nfunc countNQueens(n: Int64): Int64 {\\n    let cols = Array<Bool>(n, repeat: false)\\n    let d1 = Array<Bool>(n * 2 + 1, repeat: false)\\n    let d2 = Array<Bool>(n * 2 + 1, repeat: false)\\n    return queenTry(0, n, cols, d1, d2)\\n}"
    },
    {
      "id": 81,
      "title": "单词搜索",
      "difficulty": "中等",
      "category": "递归与回溯",
      "funcName": "existWord",
      "description": "给定由大写字母组成的二维棋盘 board（每一项是一行）与单词 word，判断单词是否存在于棋盘上：单词由相邻（上下左右）格子按顺序拼出，同一格子不能重复使用。",
      "template": "func existWord(board: Array<String>, word: String): Bool {\\n    // 请在这里实现算法（提示：棋盘 DFS + 访问标记回溯）\\n    return false\\n}",
      "tests": [
        {"call": "existWord([\\\"ABCE\\\", \\\"SFCS\\\", \\\"ADEE\\\"], \\\"ABCCED\\\")", "expect": "true"},
        {"call": "existWord([\\\"ABCE\\\", \\\"SFCS\\\", \\\"ADEE\\\"], \\\"SEE\\\")", "expect": "true"},
        {"call": "existWord([\\\"ABCE\\\", \\\"SFCS\\\", \\\"ADEE\\\"], \\\"ABCB\\\")", "expect": "false"}
      ],
      "solution": "func boardDfs(board: Array<String>, word: Array<UInt8>, i: Int64, j: Int64, k: Int64, visited: Array<Bool>): Bool {\\n    if (k == word.size) {\\n        return true\\n    }\\n    if (i < 0 || i >= board.size) {\\n        return false\\n    }\\n    let row = board[i].toArray()\\n    if (j < 0 || j >= row.size) {\\n        return false\\n    }\\n    let idx = i * 100 + j\\n    if (visited[idx] || row[j] != word[k]) {\\n        return false\\n    }\\n    visited[idx] = true\\n    let ok = boardDfs(board, word, i + 1, j, k + 1, visited) ||\\n        boardDfs(board, word, i - 1, j, k + 1, visited) ||\\n        boardDfs(board, word, i, j + 1, k + 1, visited) ||\\n        boardDfs(board, word, i, j - 1, k + 1, visited)\\n    visited[idx] = false\\n    return ok\\n}\\n\\nfunc existWord(board: Array<String>, word: String): Bool {\\n    let w = word.toArray()\\n    if (w.size == 0) {\\n        return true\\n    }\\n    let visited = Array<Bool>(board.size * 100 + 100, repeat: false)\\n    for (i in 0..board.size) {\\n        let row = board[i].toArray()\\n        for (j in 0..row.size) {\\n            if (boardDfs(board, w, i, j, 0, visited)) {\\n                return true\\n            }\\n        }\\n    }\\n    return false\\n}"
    },
    {
      "id": 82,
      "title": "腐烂的橘子",
      "difficulty": "中等",
      "category": "递归与回溯",
      "funcName": "orangesRotting",
      "description": "grid 每一项是一行：2 表示腐烂的橘子、1 表示新鲜橘子、0 表示空格。每分钟，腐烂的橘子会让它上下左右相邻的新鲜橘子变烂。返回把所有橘子变烂所需的最少分钟数；若有的橘子永远烂不了则返回 -1；本来就没有新鲜橘子则返回 0。",
      "template": "func orangesRotting(grid: Array<String>): Int64 {\\n    // 请在这里实现算法（提示：多源 BFS 逐分钟扩散）\\n    return -1\\n}",
      "tests": [
        {"call": "orangesRotting([\\\"211\\\", \\\"110\\\", \\\"011\\\"])", "expect": "4"},
        {"call": "orangesRotting([\\\"211\\\", \\\"110\\\", \\\"001\\\"])", "expect": "-1"},
        {"call": "orangesRotting([\\\"000\\\"])", "expect": "0"}
      ],
      "solution": "func orangesRotting(grid: Array<String>): Int64 {\\n    let g = ArrayList<Array<UInt8>>()\\n    for (i in 0..grid.size) {\\n        g.add(grid[i].toArray())\\n    }\\n    let rows = g.size\\n    let queue = ArrayList<Int64>()\\n    var fresh: Int64 = 0\\n    for (i in 0..rows) {\\n        let row = g[i]\\n        for (j in 0..row.size) {\\n            if (row[j] == 50) {\\n                queue.add(i * 100 + j)\\n            } else if (row[j] == 49) {\\n                fresh = fresh + 1\\n            }\\n        }\\n    }\\n    var minutes: Int64 = 0\\n    while (queue.size > 0 && fresh > 0) {\\n        var done: Int64 = 0\\n        let layer = queue.size\\n        while (done < layer) {\\n            let code = queue[0]\\n            queue.remove(at: 0)\\n            let i = code / 100\\n            let j = code % 100\\n            if (i > 0 && g[i - 1][j] == 49) {\\n                g[i - 1][j] = 50\\n                fresh = fresh - 1\\n                queue.add((i - 1) * 100 + j)\\n            }\\n            if (i + 1 < rows && g[i + 1][j] == 49) {\\n                g[i + 1][j] = 50\\n                fresh = fresh - 1\\n                queue.add((i + 1) * 100 + j)\\n            }\\n            if (j > 0 && g[i][j - 1] == 49) {\\n                g[i][j - 1] = 50\\n                fresh = fresh - 1\\n                queue.add(i * 100 + j - 1)\\n            }\\n            if (j + 1 < g[i].size && g[i][j + 1] == 49) {\\n                g[i][j + 1] = 50\\n                fresh = fresh - 1\\n                queue.add(i * 100 + j + 1)\\n            }\\n            done = done + 1\\n        }\\n        minutes = minutes + 1\\n    }\\n    if (fresh > 0) {\\n        return -1\\n    }\\n    return minutes\\n}"
    },
    {
      "id": 83,
      "title": "子集的个数",
      "difficulty": "简单",
      "category": "递归与回溯",
      "funcName": "countSubsets",
      "description": "给定互不相同的整数数组 nums，返回它所有子集的个数（包含空集与自身）。",
      "template": "func countSubsets(nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：每个元素选或不选）\\n    return 0\\n}",
      "tests": [
        {"call": "countSubsets([1, 2, 3])", "expect": "8"},
        {"call": "countSubsets([0])", "expect": "2"},
        {"call": "countSubsets([])", "expect": "1"}
      ],
      "solution": "func countSubsets(nums: Array<Int64>): Int64 {\\n    var total: Int64 = 1\\n    for (_ in 0..nums.size) {\\n        total = total * 2\\n    }\\n    return total\\n}"
    },
    {
      "id": 84,
      "title": "电话号码的字母组合",
      "difficulty": "中等",
      "category": "递归与回溯",
      "funcName": "countLetterCombinations",
      "description": "给定数字字符串 digits（2 到 9 之间），返回它能表示的所有字母组合的个数。2 到 9 分别对应 abc、def、ghi、jkl、mno、pqrs、tuv、wxyz，空字符串返回 0。",
      "template": "func countLetterCombinations(digits: String): Int64 {\\n    // 请在这里实现算法（提示：各位可选项个数相乘）\\n    return 0\\n}",
      "tests": [
        {"call": "countLetterCombinations(\\\"23\\\")", "expect": "9"},
        {"call": "countLetterCombinations(\\\"\\\")", "expect": "0"},
        {"call": "countLetterCombinations(\\\"2\\\")", "expect": "3"},
        {"call": "countLetterCombinations(\\\"79\\\")", "expect": "16"}
      ],
      "solution": "func countLetterCombinations(digits: String): Int64 {\\n    if (digits.size == 0) {\\n        return 0\\n    }\\n    var total: Int64 = 1\\n    for (c in digits.toArray()) {\\n        let d = Int64(c) - 48\\n        if (d == 7 || d == 9) {\\n            total = total * 4\\n        } else if (d >= 2 && d <= 8) {\\n            total = total * 3\\n        } else {\\n            return 0\\n        }\\n    }\\n    return total\\n}"
    },
    {
      "id": 85,
      "title": "跳跃游戏",
      "difficulty": "中等",
      "category": "贪心",
      "funcName": "canJump",
      "description": "给定非负整数数组 nums，nums[i] 表示从下标 i 最多能往前跳几步。从下标 0 出发，判断能否到达最后一个下标。",
      "template": "func canJump(nums: Array<Int64>): Bool {\\n    // 请在这里实现算法（提示：维护能到达的最远下标）\\n    return false\\n}",
      "tests": [
        {"call": "canJump([2, 3, 1, 1, 4])", "expect": "true"},
        {"call": "canJump([3, 2, 1, 0, 4])", "expect": "false"},
        {"call": "canJump([0])", "expect": "true"}
      ],
      "solution": "func canJump(nums: Array<Int64>): Bool {\\n    var reach: Int64 = 0\\n    var i: Int64 = 0\\n    while (i < nums.size) {\\n        if (i > reach) {\\n            return false\\n        }\\n        let r = i + nums[i]\\n        if (r > reach) {\\n            reach = r\\n        }\\n        i = i + 1\\n    }\\n    return true\\n}"
    },
    {
      "id": 86,
      "title": "跳跃游戏 II",
      "difficulty": "中等",
      "category": "贪心",
      "funcName": "jump",
      "description": "给定非负整数数组 nums（保证一定能到达最后一个下标），nums[i] 表示从下标 i 最多能往前跳几步。返回从下标 0 跳到最后一个下标所需的最少步数。",
      "template": "func jump(nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：每层边界内取最远，跳一步）\\n    return 0\\n}",
      "tests": [
        {"call": "jump([2, 3, 1, 1, 4])", "expect": "2"},
        {"call": "jump([2, 3, 0, 1, 4])", "expect": "2"},
        {"call": "jump([0])", "expect": "0"}
      ],
      "solution": "func jump(nums: Array<Int64>): Int64 {\\n    var steps: Int64 = 0\\n    var curEnd: Int64 = 0\\n    var farthest: Int64 = 0\\n    var i: Int64 = 0\\n    while (i < nums.size - 1) {\\n        if (i + nums[i] > farthest) {\\n            farthest = i + nums[i]\\n        }\\n        if (i == curEnd) {\\n            steps = steps + 1\\n            curEnd = farthest\\n        }\\n        i = i + 1\\n    }\\n    return steps\\n}"
    },
    {
      "id": 87,
      "title": "种花问题",
      "difficulty": "简单",
      "category": "贪心",
      "funcName": "canPlaceFlowers",
      "description": "flowerbed 里 1 表示已种花、0 表示空地，花不能种在相邻的地块上。判断能否再种下 n 朵花。",
      "template": "func canPlaceFlowers(flowerbed: Array<Int64>, n: Int64): Bool {\\n    // 请在这里实现算法（提示：贪心：能种就种并跳一格）\\n    return false\\n}",
      "tests": [
        {"call": "canPlaceFlowers([1, 0, 0, 0, 1], 1)", "expect": "true"},
        {"call": "canPlaceFlowers([1, 0, 0, 0, 1], 2)", "expect": "false"},
        {"call": "canPlaceFlowers([0, 0, 1, 0, 0], 2)", "expect": "true"}
      ],
      "solution": "func canPlaceFlowers(flowerbed: Array<Int64>, n: Int64): Bool {\\n    var planted: Int64 = 0\\n    var i: Int64 = 0\\n    while (i < flowerbed.size) {\\n        if (flowerbed[i] == 0) {\\n            let leftOk = i == 0 || flowerbed[i - 1] == 0\\n            let rightOk = i + 1 == flowerbed.size || flowerbed[i + 1] == 0\\n            if (leftOk && rightOk) {\\n                planted = planted + 1\\n                i = i + 2\\n                continue\\n            }\\n        }\\n        i = i + 1\\n    }\\n    return planted >= n\\n}"
    },
    {
      "id": 88,
      "title": "加油站",
      "difficulty": "中等",
      "category": "贪心",
      "funcName": "canCompleteCircuit",
      "description": "环形路线上有 n 个加油站：gas[i] 是第 i 站的油量，cost[i] 是从第 i 站开往下一站的耗油。油箱初始为空，返回能绕行一周的出发站下标；不存在则返回 -1（保证答案唯一）。",
      "template": "func canCompleteCircuit(gas: Array<Int64>, cost: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：累计油量不足就重置起点）\\n    return -1\\n}",
      "tests": [
        {"call": "canCompleteCircuit([1, 2, 3, 4, 5], [3, 4, 5, 1, 2])", "expect": "3"},
        {"call": "canCompleteCircuit([2, 3, 4], [3, 4, 3])", "expect": "-1"},
        {"call": "canCompleteCircuit([5], [4])", "expect": "0"}
      ],
      "solution": "func canCompleteCircuit(gas: Array<Int64>, cost: Array<Int64>): Int64 {\\n    var total: Int64 = 0\\n    var cur: Int64 = 0\\n    var start: Int64 = 0\\n    var i: Int64 = 0\\n    while (i < gas.size) {\\n        let diff = gas[i] - cost[i]\\n        total = total + diff\\n        cur = cur + diff\\n        if (cur < 0) {\\n            start = i + 1\\n            cur = 0\\n        }\\n        i = i + 1\\n    }\\n    if (total < 0) {\\n        return -1\\n    }\\n    return start\\n}"
    },
    {
      "id": 89,
      "title": "买卖股票的最佳时机 II",
      "difficulty": "中等",
      "category": "贪心",
      "funcName": "maxProfitII",
      "description": "给定股票每天的价格数组 prices，每天都可以买入或卖出（同一时刻最多持有一股），返回能获得的最大利润。",
      "template": "func maxProfitII(prices: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：把每一段上涨都收下）\\n    return 0\\n}",
      "tests": [
        {"call": "maxProfitII([7, 1, 5, 3, 6, 4])", "expect": "7"},
        {"call": "maxProfitII([1, 2, 3, 4, 5])", "expect": "4"},
        {"call": "maxProfitII([7, 6, 4, 3, 1])", "expect": "0"}
      ],
      "solution": "func maxProfitII(prices: Array<Int64>): Int64 {\\n    var profit: Int64 = 0\\n    var i: Int64 = 1\\n    while (i < prices.size) {\\n        if (prices[i] > prices[i - 1]) {\\n            profit = profit + (prices[i] - prices[i - 1])\\n        }\\n        i = i + 1\\n    }\\n    return profit\\n}"
    },
    {
      "id": 90,
      "title": "拼接最大数",
      "difficulty": "中等",
      "category": "贪心",
      "funcName": "maxNumber",
      "description": "给定非负整数数组 nums，把它们重新排列后拼接成一个字符串，使结果尽可能大，返回这个字符串（各个数本身不能拆开，全为 0 时返回单个 0）。",
      "template": "func maxNumber(nums: Array<Int64>): String {\\n    // 请在这里实现算法（提示：按拼接结果排序后拼起来）\\n    return \\\"\\\"\\n}",
      "tests": [
        {"call": "maxNumber([10, 2])", "expect": "\\\"210\\\""},
        {"call": "maxNumber([3, 30, 34, 5, 9])", "expect": "\\\"9534330\\\""},
        {"call": "maxNumber([0, 0])", "expect": "\\\"0\\\""}
      ],
      "solution": "func strGreater(a: String, b: String): Bool {\\n    let x = a.toArray()\\n    let y = b.toArray()\\n    var i: Int64 = 0\\n    while (i < x.size && i < y.size) {\\n        if (x[i] != y[i]) {\\n            return x[i] > y[i]\\n        }\\n        i = i + 1\\n    }\\n    return x.size > y.size\\n}\\n\\nfunc maxNumber(nums: Array<Int64>): String {\\n    let parts = ArrayList<String>()\\n    for (x in nums) {\\n        parts.add(x.toString())\\n    }\\n    let n = parts.size\\n    var i: Int64 = 0\\n    while (i < n) {\\n        var m = i\\n        var j = i + 1\\n        while (j < n) {\\n            if (strGreater(parts[j] + parts[m], parts[m] + parts[j])) {\\n                m = j\\n            }\\n            j = j + 1\\n        }\\n        if (m != i) {\\n            let t = parts[i]\\n            parts[i] = parts[m]\\n            parts[m] = t\\n        }\\n        i = i + 1\\n    }\\n    var out = \\\"\\\"\\n    for (p in parts) {\\n        out = out + p\\n    }\\n    var allZero = true\\n    for (c in out.toArray()) {\\n        if (c != 48) {\\n            allZero = false\\n        }\\n    }\\n    if (allZero && out.size > 1) {\\n        return \\\"0\\\"\\n    }\\n    return out\\n}"
    },
    {
      "id": 91,
      "title": "乘积最大子数组",
      "difficulty": "中等",
      "category": "动态规划",
      "funcName": "maxProduct",
      "description": "给定整数数组 nums，返回其中乘积最大的连续子数组的乘积。",
      "template": "func maxProduct(nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：同时盯住以当前元素结尾的最大与最小乘积）\\n    return 0\\n}",
      "tests": [
        {"call": "maxProduct([2, 3, -2, 4])", "expect": "6"},
        {"call": "maxProduct([-2, 0, -1])", "expect": "0"},
        {"call": "maxProduct([-2, 3, -4])", "expect": "24"}
      ],
      "solution": "func maxProduct(nums: Array<Int64>): Int64 {\\n    var best = nums[0]\\n    var curMax = nums[0]\\n    var curMin = nums[0]\\n    for (i in 1..nums.size) {\\n        let x = nums[i]\\n        let a = curMax * x\\n        let b = curMin * x\\n        var mx = a\\n        if (b > mx) {\\n            mx = b\\n        }\\n        if (x > mx) {\\n            mx = x\\n        }\\n        var mn = a\\n        if (b < mn) {\\n            mn = b\\n        }\\n        if (x < mn) {\\n            mn = x\\n        }\\n        curMax = mx\\n        curMin = mn\\n        if (curMax > best) {\\n            best = curMax\\n        }\\n    }\\n    return best\\n}"
    },
    {
      "id": 92,
      "title": "使用最小花费爬楼梯",
      "difficulty": "简单",
      "category": "动态规划",
      "funcName": "minCostClimbingStairs",
      "description": "cost[i] 表示从第 i 级台阶向上走需要付的费用。可以从下标 0 或下标 1 出发，每次迈 1 级或 2 级，返回走到阶梯顶部（越过最后一级）的最小花费。",
      "template": "func minCostClimbingStairs(cost: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：dp 只留前两级的最优值）\\n    return 0\\n}",
      "tests": [
        {"call": "minCostClimbingStairs([10, 15, 20])", "expect": "15"},
        {"call": "minCostClimbingStairs([1, 100, 1, 1, 1, 100, 1, 1, 100, 1])", "expect": "6"},
        {"call": "minCostClimbingStairs([0, 0])", "expect": "0"}
      ],
      "solution": "func minCostClimbingStairs(cost: Array<Int64>): Int64 {\\n    let n = cost.size\\n    var prev2: Int64 = 0\\n    var prev1: Int64 = 0\\n    var i: Int64 = 2\\n    while (i <= n) {\\n        var take = prev1 + cost[i - 1]\\n        let other = prev2 + cost[i - 2]\\n        if (other < take) {\\n            take = other\\n        }\\n        prev2 = prev1\\n        prev1 = take\\n        i = i + 1\\n    }\\n    return prev1\\n}"
    },
    {
      "id": 93,
      "title": "不同路径",
      "difficulty": "中等",
      "category": "动态规划",
      "funcName": "uniquePaths",
      "description": "一个机器人位于 m 行 n 列网格的左上角，每次只能向下或向右走一步，返回它到达右下角共有多少条不同路径。",
      "template": "func uniquePaths(m: Int64, n: Int64): Int64 {\\n    // 请在这里实现算法（提示：一行 dp 从左往右累加）\\n    return 0\\n}",
      "tests": [
        {"call": "uniquePaths(3, 7)", "expect": "28"},
        {"call": "uniquePaths(3, 2)", "expect": "3"},
        {"call": "uniquePaths(1, 1)", "expect": "1"}
      ],
      "solution": "func uniquePaths(m: Int64, n: Int64): Int64 {\\n    let dp = Array<Int64>(n, repeat: 1)\\n    var i: Int64 = 1\\n    while (i < m) {\\n        var j: Int64 = 1\\n        while (j < n) {\\n            dp[j] = dp[j] + dp[j - 1]\\n            j = j + 1\\n        }\\n        i = i + 1\\n    }\\n    return dp[n - 1]\\n}"
    },
    {
      "id": 94,
      "title": "零钱兑换",
      "difficulty": "中等",
      "category": "动态规划",
      "funcName": "coinChange",
      "description": "给定不同面额的硬币 coins 与总金额 amount，每种硬币数量不限，返回凑出该金额所需的最少硬币个数；凑不出则返回 -1。",
      "template": "func coinChange(coins: Array<Int64>, amount: Int64): Int64 {\\n    // 请在这里实现算法（提示：完全背包求最少硬币数）\\n    return -1\\n}",
      "tests": [
        {"call": "coinChange([1, 2, 5], 11)", "expect": "3"},
        {"call": "coinChange([2], 3)", "expect": "-1"},
        {"call": "coinChange([1], 0)", "expect": "0"}
      ],
      "solution": "func coinChange(coins: Array<Int64>, amount: Int64): Int64 {\\n    let big = amount + 1\\n    let dp = Array<Int64>(amount + 1, repeat: big)\\n    dp[0] = 0\\n    var i: Int64 = 1\\n    while (i <= amount) {\\n        for (c in coins) {\\n            if (c <= i) {\\n                let cand = dp[i - c] + 1\\n                if (cand < dp[i]) {\\n                    dp[i] = cand\\n                }\\n            }\\n        }\\n        i = i + 1\\n    }\\n    if (dp[amount] > amount) {\\n        return -1\\n    }\\n    return dp[amount]\\n}"
    },
    {
      "id": 95,
      "title": "最长递增子序列",
      "difficulty": "中等",
      "category": "动态规划",
      "funcName": "lengthOfLIS",
      "description": "给定整数数组 nums，返回其中最长的严格递增子序列的长度（子序列不要求连续）。",
      "template": "func lengthOfLIS(nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：以每个位置结尾的最长长度）\\n    return 0\\n}",
      "tests": [
        {"call": "lengthOfLIS([10, 9, 2, 5, 3, 7, 101, 18])", "expect": "4"},
        {"call": "lengthOfLIS([0, 1, 0, 3, 2, 3])", "expect": "4"},
        {"call": "lengthOfLIS([7, 7, 7, 7])", "expect": "1"}
      ],
      "solution": "func lengthOfLIS(nums: Array<Int64>): Int64 {\\n    let n = nums.size\\n    if (n == 0) {\\n        return 0\\n    }\\n    let dp = Array<Int64>(n, repeat: 1)\\n    var best: Int64 = 1\\n    var i: Int64 = 1\\n    while (i < n) {\\n        var j: Int64 = 0\\n        while (j < i) {\\n            if (nums[j] < nums[i] && dp[j] + 1 > dp[i]) {\\n                dp[i] = dp[j] + 1\\n            }\\n            j = j + 1\\n        }\\n        if (dp[i] > best) {\\n            best = dp[i]\\n        }\\n        i = i + 1\\n    }\\n    return best\\n}"
    },
    {
      "id": 96,
      "title": "完全平方数",
      "difficulty": "中等",
      "category": "动态规划",
      "funcName": "numSquares",
      "description": "给定正整数 n，返回把它表示成若干个完全平方数之和所需的最少个数（完全平方数可以重复使用）。",
      "template": "func numSquares(n: Int64): Int64 {\\n    // 请在这里实现算法（提示：逐个减去平方数取最小）\\n    return 0\\n}",
      "tests": [
        {"call": "numSquares(12)", "expect": "3"},
        {"call": "numSquares(13)", "expect": "2"},
        {"call": "numSquares(1)", "expect": "1"}
      ],
      "solution": "func numSquares(n: Int64): Int64 {\\n    let dp = Array<Int64>(n + 1, repeat: n + 1)\\n    dp[0] = 0\\n    var i: Int64 = 1\\n    while (i <= n) {\\n        var k: Int64 = 1\\n        while (k * k <= i) {\\n            let cand = dp[i - k * k] + 1\\n            if (cand < dp[i]) {\\n                dp[i] = cand\\n            }\\n            k = k + 1\\n        }\\n        i = i + 1\\n    }\\n    return dp[n]\\n}"
    },
    {
      "id": 97,
      "title": "最长公共子序列的长度",
      "difficulty": "中等",
      "category": "动态规划",
      "funcName": "longestCommonSubsequenceLen",
      "description": "给定两个字符串 a 与 b，返回它们最长公共子序列的长度（子序列不要求连续）。",
      "template": "func longestCommonSubsequenceLen(a: String, b: String): Int64 {\\n    // 请在这里实现算法（提示：二维 dp 压成一维滚动）\\n    return 0\\n}",
      "tests": [
        {"call": "longestCommonSubsequenceLen(\\\"abcde\\\", \\\"ace\\\")", "expect": "3"},
        {"call": "longestCommonSubsequenceLen(\\\"abc\\\", \\\"abc\\\")", "expect": "3"},
        {"call": "longestCommonSubsequenceLen(\\\"abc\\\", \\\"def\\\")", "expect": "0"}
      ],
      "solution": "func longestCommonSubsequenceLen(a: String, b: String): Int64 {\\n    let x = a.toArray()\\n    let y = b.toArray()\\n    let n = y.size\\n    var prev = Array<Int64>(n + 1, repeat: 0)\\n    var i: Int64 = 1\\n    while (i <= x.size) {\\n        let cur = Array<Int64>(n + 1, repeat: 0)\\n        var j: Int64 = 1\\n        while (j <= n) {\\n            if (x[i - 1] == y[j - 1]) {\\n                cur[j] = prev[j - 1] + 1\\n            } else if (prev[j] > cur[j - 1]) {\\n                cur[j] = prev[j]\\n            } else {\\n                cur[j] = cur[j - 1]\\n            }\\n            j = j + 1\\n        }\\n        prev = cur\\n        i = i + 1\\n    }\\n    return prev[n]\\n}"
    },
    {
      "id": 98,
      "title": "和为 K 的子数组",
      "difficulty": "中等",
      "category": "动态规划",
      "funcName": "subarraySum",
      "description": "给定整数数组 nums 与整数 k，统计有多少个连续子数组的元素之和恰好等于 k。",
      "template": "func subarraySum(nums: Array<Int64>, k: Int64): Int64 {\\n    // 请在这里实现算法（提示：前缀和 + 哈希表计数）\\n    return 0\\n}",
      "tests": [
        {"call": "subarraySum([1, 1, 1], 2)", "expect": "2"},
        {"call": "subarraySum([1, 2, 3], 3)", "expect": "2"},
        {"call": "subarraySum([1, -1, 0], 0)", "expect": "3"}
      ],
      "solution": "func subarraySum(nums: Array<Int64>, k: Int64): Int64 {\\n    let seen = HashMap<Int64, Int64>()\\n    seen.add(0, 1)\\n    var sum: Int64 = 0\\n    var count: Int64 = 0\\n    for (x in nums) {\\n        sum = sum + x\\n        if (let Some(v) <- seen.get(sum - k)) {\\n            count = count + v\\n        }\\n        var cur: Int64 = 0\\n        if (let Some(v) <- seen.get(sum)) {\\n            cur = v\\n        }\\n        seen.add(sum, cur + 1)\\n    }\\n    return count\\n}"
    },
    {
      "id": 99,
      "title": "寻找旋转排序数组中的最小值",
      "difficulty": "中等",
      "category": "二分与排序",
      "funcName": "findMinRotated",
      "description": "给定一个升序数组在某个位置被旋转后的结果（元素互不相同），例如 [3,4,5,1,2]，在 O(log n) 时间内返回数组中的最小元素。",
      "template": "func findMinRotated(nums: Array<Int64>): Int64 {\\n    // 请在这里实现算法（提示：与右端点比较决定丢弃哪一半）\\n    return 0\\n}",
      "tests": [
        {"call": "findMinRotated([3, 4, 5, 1, 2])", "expect": "1"},
        {"call": "findMinRotated([4, 5, 6, 7, 0, 1, 2])", "expect": "0"},
        {"call": "findMinRotated([11, 13, 15, 17])", "expect": "11"}
      ],
      "solution": "func findMinRotated(nums: Array<Int64>): Int64 {\\n    var lo: Int64 = 0\\n    var hi: Int64 = nums.size - 1\\n    while (lo < hi) {\\n        let mid = lo + (hi - lo) / 2\\n        if (nums[mid] > nums[hi]) {\\n            lo = mid + 1\\n        } else {\\n            hi = mid\\n        }\\n    }\\n    return nums[lo]\\n}"
    },
    {
      "id": 100,
      "title": "搜索旋转排序数组",
      "difficulty": "中等",
      "category": "二分与排序",
      "funcName": "searchRotated",
      "description": "给定一个升序数组在某个位置被旋转后的结果（元素互不相同），例如 [4,5,6,7,0,1,2]。在 O(log n) 时间内查找 target 并返回下标，不存在返回 -1。",
      "template": "func searchRotated(nums: Array<Int64>, target: Int64): Int64 {\\n    // 请在这里实现算法（提示：每次先判断哪一半有序）\\n    return -1\\n}",
      "tests": [
        {"call": "searchRotated([4, 5, 6, 7, 0, 1, 2], 0)", "expect": "4"},
        {"call": "searchRotated([4, 5, 6, 7, 0, 1, 2], 3)", "expect": "-1"},
        {"call": "searchRotated([1], 0)", "expect": "-1"}
      ],
      "solution": "func searchRotated(nums: Array<Int64>, target: Int64): Int64 {\\n    var lo: Int64 = 0\\n    var hi: Int64 = nums.size - 1\\n    while (lo <= hi) {\\n        let mid = lo + (hi - lo) / 2\\n        if (nums[mid] == target) {\\n            return mid\\n        }\\n        if (nums[lo] <= nums[mid]) {\\n            if (target >= nums[lo] && target < nums[mid]) {\\n                hi = mid - 1\\n            } else {\\n                lo = mid + 1\\n            }\\n        } else {\\n            if (target > nums[mid] && target <= nums[hi]) {\\n                lo = mid + 1\\n            } else {\\n                hi = mid - 1\\n            }\\n        }\\n    }\\n    return -1\\n}"
    }
  ]
}
"""

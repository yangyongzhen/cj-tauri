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
 *   · 用例里字符串字面量的引号必须写成 \\\\\"（否则提前终止 JSON 字符串）。
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
      ]
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
        {"call": "majorityElement([2, 2, 1, 1, 1, 2, 2])", "expect": "2"}
      ]
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
      ]
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
      ]
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
      ]
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
      ]
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
      ]
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
      ]
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
      ]
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
        {"call": "minStackFinal([2, 1, -2, -1, 4, -2])", "expect": "4"},
        {"call": "minStackFinal([9, -2])", "expect": "9"}
      ]
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
      ]
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
      ]
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
      ]
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
      ]
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
      ]
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
      ]
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
      ]
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
      ]
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
      ]
    }
  ]
}
"""

---
name: frontend-tech-stack
version: "3.29.5"
description: >-
  前端技术栈约束与版本要求。配合 /devflow P3 编码阶段使用。
  ：Node.js/pnpm 版本约束，i18n 和 a11y 检查项。
metadata:
  tags: "frontend,tech-stack,vue,typescript"
---

# 前端技术栈约束 (v3.5)

> **目的**：规范前端开发环境，确保团队协作和构建一致性。

## 1. 核心依赖版本约束

### 1.1 必须版本

| 依赖 | 最低版本 | 推荐版本 | 说明 |
|------|----------|----------|------|
| Node.js | >=18.0.0 | 20.x LTS | 后端服务兼容 |
| npm | >=9.0.0 | 10.x | - |
| pnpm | >=8.0.0 | 9.x | 推荐使用 |
| Vue | 3.x | 3.4+ | 组合式 API |
| TypeScript | >=5.0 | 5.3+ | 类型安全 |
| Vite | >=5.0 | 5.4+ | 构建工具 |
| Pinia | >=2.0 | 2.1+ | 状态管理 |
| Vue Router | >=4.0 | 4.3+ | 路由 |

### 1.2 版本验证

```bash
# 检查 Node.js 版本
node --version  # >= v18.0.0

# 检查 npm 版本
npm --version   # >= 9.0.0

# 检查 pnpm 版本
pnpm --version # >= 8.0.0
```

### 1.3 package.json 约束示例

```json
{
  "engines": {
    "node": ">=18.0.0",
    "pnpm": ">=8.0.0"
  },
  "packageManager": "pnpm@9.0.0"
}
```

## 2. 项目结构规范

### 2.1 目录结构

```
frontend/
├── src/
│   ├── api/              # API 调用封装
│   ├── assets/           # 静态资源
│   ├── components/      # 公共组件
│   ├── composables/     # 组合式函数
│   ├── layouts/          # 布局组件
│   ├── router/          # 路由配置
│   ├── stores/          # Pinia 状态
│   ├── types/           # TypeScript 类型
│   ├── utils/           # 工具函数
│   ├── views/           # 页面组件
│   ├── App.vue
│   └── main.ts
├── tests/               # 测试文件
│   ├── e2e/            # E2E 测试
│   ├── helpers.ts      # 测试辅助
│   └── .env.test       # 测试环境变量
├── package.json
├── pnpm-lock.yaml
├── tsconfig.json
├── vite.config.ts
└── .npmrc
```

### 2.2 命名规范

| 类型 | 规范 | 示例 |
|------|------|------|
| 组件文件 | PascalCase | `UserProfile.vue` |
| 组合式函数 | camelCase + use 前缀 | `useAuth.ts` |
| 工具函数 | camelCase | `formatDate.ts` |
| 样式文件 | kebab-case | `user-profile.scss` |
| 类型文件 | PascalCase | `UserType.ts` |

## 3. 代码规范

### 3.1 Vue 组件规范

```vue
<!-- ✓ 推荐：组合式 API + defineProps -->
<script setup lang="ts">
import { ref, computed } from 'vue'
import type { User } from '@/types'

interface Props {
  user: User
  editable?: boolean
}

const props = withDefaults(defineProps<Props>(), {
  editable: false
})

const emit = defineEmits<{
  update: [user: User]
}>()

const isLoading = ref(false)
const userName = computed(() => props.user.name)
</script>

<template>
  <div class="user-profile">
    <h2>{{ userName }}</h2>
  </div>
</template>

<style scoped>
.user-profile {
  padding: 1rem;
}
</style>
```

### 3.2 禁止事项

| 禁止 | 原因 | 替代方案 |
|------|------|----------|
| Options API | 难以维护 | Composition API |
| `any` 类型 | 失去类型安全 | 明确类型定义 |
| 裸 `fetch` | 缺少错误处理 | 使用封装 API |
| 硬编码路径 | 难以维护 | 使用别名 |
| 魔法数字 | 难以理解 | 使用常量 |

## 4. 样式规范

### 4.1 CSS 变量

```css
:root {
  /* 颜色 */
  --color-primary: #409eff;
  --color-success: #67c23a;
  --color-warning: #e6a23c;
  --color-danger: #f56c6c;
  
  /* 间距 */
  --spacing-xs: 4px;
  --spacing-sm: 8px;
  --spacing-md: 16px;
  --spacing-lg: 24px;
  
  /* 圆角 */
  --radius-sm: 4px;
  --radius-md: 8px;
}
```

### 4.2 命名空间

```css
/* 组件样式使用 scoped */
<style scoped>
.user-card {
  /* 组件特定样式 */
}
</style>

/* 全局样式使用特定前缀 */
.xy-btn {
  /* 全局按钮样式 */
}
```

## 5. i18n 规范

### 5.1 必须国际化场景

| 场景 | 是否需要 | 示例 |
|------|----------|------|
| 用户可见文本 | ✅ 必须 | 按钮文字、标题 |
| 表单验证消息 | ✅ 必须 | "用户名不能为空" |
| 错误消息 | ✅ 必须 | "网络错误" |
| 日期/数字格式化 | ✅ 必须 | 货币、日期 |
| 组件内部状态 | ⚠️ 建议 | loading、empty |
| 技术术语 | ❌ 可选 | API、JSON |

### 5.2 i18n 检查

```bash
# 检测硬编码中文
grep -rnE "[^\x00-\x7F]{2,}" frontend/src/views/ | grep -v "\.spec\.ts" | head -20

# 检测 i18n 函数使用
grep -rnE "t\(['\"]" frontend/src/views/ | wc -l
```

### 5.3 国际化文件结构

```
frontend/src/
├── locales/
│   ├── index.ts
│   ├── zh-CN/
│   │   ├── common.ts      # 公共翻译
│   │   └── user.ts        # 用户模块
│   └── en/
│       ├── common.ts
│       └── user.ts
```

## 6. 无障碍规范（a11y）

### 6.1 必须检查项

| 检查项 | 说明 | 验证方法 |
|--------|------|----------|
| 语义化标签 | 使用 `button` 而非 `div` | `eslint-plugin-jsx-a11y` |
| ARIA 属性 | 交互元素必须有标签 | 手动检查 |
| 键盘导航 | 支持 Tab/Enter/Esc | 手动测试 |
| 颜色对比度 | 文字与背景对比度 >= 4.5:1 | 工具检测 |
| 表单标签 | 输入框必须有 label | `eslint-plugin-jsx-a11y` |

### 6.2 常见问题修复

```vue
<!-- ❌ 错误 -->
<div @click="handleClick">点击我</div>
<input type="text">

<!-- ✓ 正确 -->
<button @click="handleClick">点击我</button>
<label>
  用户名
  <input type="text" aria-describedby="username-help">
</label>
<span id="username-help" class="sr-only">6-20个字符</span>
```

### 6.3 a11y 检查命令

```bash
# ESLint a11y 检查
npm run lint

# 手动测试
# 1. 只用键盘操作（Tab, Enter, Space, Esc）
# 2. 使用屏幕阅读器测试
# 3. 检查颜色对比度
```

## 7. 自检命令

### 7.1 版本检查

```bash
# 检查 Node.js 版本
node --version | grep -qE "^v(18|20|22)\." && echo "PASS" || echo "FAIL"

# 检查 pnpm 版本
pnpm --version | grep -qE "^[89]\." && echo "PASS" || echo "FAIL"
```

### 7.2 依赖检查

```bash
# 检查 lock 文件存在
test -f frontend/pnpm-lock.yaml && echo "PASS" || echo "FAIL"

# 检查依赖一致性
cd frontend && pnpm install --frozen-lockfile && echo "PASS" || echo "FAIL"
```

---

## Changelog

| 版本 | 日期 | 变更 |
|------|------|------|
| v3.5.0 | 2026-08-12 | 新增 i18n 和 a11y 规范 |
| v3.0.0 | 2026-07-28 | 初始版本 |

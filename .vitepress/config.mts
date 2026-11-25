import { defineConfig } from 'vitepress'

// GitHub Pages 部署在 /SSMT4-Tutorial/ 子路径下。
// CI 通过 DOCS_BASE 环境变量注入；本地（dev / build / preview）默认根路径。
const base = process.env.DOCS_BASE || '/'

export default defineConfig({
  base,

  lang: 'zh-CN',
  title: '转储到模型',
  description: '从 3DMigoto 转储文件到 Blender 模型 —— 全流程教程',

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: `${base}logo.svg` }],
  ],

  sitemap: {
    hostname: 'https://linstar2006.github.io/SSMT4-Tutorial/',
  },

  themeConfig: {
    nav: [
      { text: '首页', link: '/' },
      { text: '入门教程', link: '/guide/' },
      { text: '实战案例', link: '/case/7ad7e69e' },
      { text: '原理与进阶', link: '/dev/ssmt4-internals' },
    ],

    sidebar: {
      '/guide/': [
        {
          text: '开始之前',
          items: [
            { text: '这套教程讲什么', link: '/guide/' },
            { text: '需要准备什么', link: '/guide/preparation' },
          ],
        },
        {
          text: '第一步：拿到转储',
          items: [
            { text: '认识 FrameAnalysis 目录', link: '/guide/dump/anatomy' },
            { text: '抓取一次转储', link: '/guide/dump/capture' },
            { text: '锁定目标 IB', link: '/guide/dump/find-ib' },
          ],
        },
        {
          text: '第二步：搞懂数据类型',
          items: [
            { text: '数据类型到底是什么', link: '/guide/gametype/what-is-gametype' },
            { text: 'GPU 与 CPU 预蒙皮', link: '/guide/gametype/preskinning' },
            { text: '从转储推导数据类型', link: '/guide/gametype/derive' },
          ],
        },
        {
          text: '第三步：提取数据',
          items: [
            { text: '读输入布局', link: '/guide/extract/layout' },
            { text: '切顶点与索引', link: '/guide/extract/vertices' },
            { text: '提取贴图', link: '/guide/extract/textures' },
          ],
        },
        {
          text: '第四步：导入 Blender',
          items: [
            { text: 'OBJ 路线（最快）', link: '/guide/blender/obj' },
            { text: '脚本路线（完整）', link: '/guide/blender/script' },
            { text: '顶点色与 UV', link: '/guide/blender/vertex-color' },
          ],
        },
        {
          text: '第五步：做回 Mod',
          items: [
            { text: '回写坐标与数据', link: '/guide/mod/writeback' },
          ],
        },
      ],
      '/case/': [
        {
          text: '实战案例',
          items: [
            { text: '7ad7e69e 全流程复盘', link: '/case/7ad7e69e' },
          ],
        },
      ],
      '/dev/': [
        {
          text: '原理与进阶',
          items: [
            { text: 'SSMT4 内部是怎么做的', link: '/dev/ssmt4-internals' },
            { text: '术语表', link: '/dev/glossary' },
          ],
        },
      ],
    },

    outline: { level: [2, 3], label: '本页目录' },

    docFooter: {
      prev: '上一页',
      next: '下一页',
    },

    lastUpdated: {
      text: '最后更新于',
      formatOptions: { dateStyle: 'short', timeStyle: 'medium' },
    },

    search: {
      provider: 'local',
      options: {
        translations: {
          button: {
            buttonText: '搜索文档',
            buttonAriaLabel: '搜索文档',
          },
          modal: {
            noResultsText: '没有找到结果',
            resetButtonTitle: '清除查询',
            footer: {
              selectText: '选择',
              navigateText: '切换',
              closeText: '关闭',
            },
          },
        },
      },
    },

    returnToTopLabel: '回到顶部',
    sidebarMenuLabel: '菜单',
    darkModeSwitchLabel: '主题',
    langMenuLabel: '语言',

    socialLinks: [
      { icon: 'github', link: 'https://github.com/Perxenic-Acid/SSMT4' },
    ],

    footer: {
      message: '基于 3DMigoto 与 SSMT4 的实际数据流整理',
      copyright: '内容可自由转载，注明来源即可',
    },
  },

  markdown: {
    lineNumbers: true,
    theme: {
      light: 'github-light',
      dark: 'github-dark',
    },
  },

  cleanUrls: true,

  // 仓库说明文件不参与站点渲染
  srcExclude: ['README.md'],
})
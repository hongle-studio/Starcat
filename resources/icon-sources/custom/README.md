# Starcat 定制 Fork 图标

根据 dong4j 确认的参考图绘制，不属于 Lucide 图标集，不额外引入第三方图标依赖。

| 资源 | 图形及业务含义 | 使用位置 |
|---|---|---|
| `BusinessForkedRepository` | Y 形三节点；仓库派生自其他项目 | 卡片标题、派生来源、隐藏 Fork 筛选、集合 Fork 身份 |
| `BusinessForkCount` | 双箭头指向相连节点；被其他人 Fork 的次数 | 卡片与详情的 Forks 统计、活动与搜索统计 |

两枚 SVG 均为 24×24 网格、2px 圆角描边、透明背景。Asset Catalog 编译为矢量模板；实际大小由原控件字号决定。Forked 身份徽章使用绿色和浅绿色胶囊背景，次数统计保留蓝色；明暗主题均由 `StatSemanticColor` 解析，不能把预览的色块或 24px 网格直接带入布局。

身份与次数必须保持分离；执行 Fork、同步上游、查看分支等操作图标不属于这两项展示语义。

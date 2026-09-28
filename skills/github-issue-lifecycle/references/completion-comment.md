# 完成评论

在关闭已验收 Issue 前发布一条英文评论。marker 必须恰好出现一次，便于重试时识别已有评论。

```markdown
<!-- github-issue-lifecycle:completion -->
Implemented and verified.

## Changes

- <User-visible or architectural outcome>
- <Second material outcome, when applicable>

## Verification

- `<command or check>` — passed
- <Manual or reviewer acceptance evidence, when applicable>

## References

- Commit: <published commit URL or SHA, when available>
- Pull request: <URL, when available>

Closing this issue as completed following review and explicit acceptance.
```

## 生成规则

- 删除空的可选 section 或 row，不写 `N/A`。
- 只有用户明确接受剩余风险时才能写失败或跳过的验证；否则保持 Issue Open。
- 当前远端 check state 没有证明时，不能声称 CI passed。
- 仅存在于本地的 commit 或 pull request 不能写成已经发布。
- 总结交付结果，不复制完整执行过程。
- 不能包含 secret 或敏感本地路径。

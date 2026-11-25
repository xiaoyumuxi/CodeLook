# Bridge/internal：语法引擎

这里是 Lithe 编辑器的语法引擎，从 Lithe-IDEA 的 `desktop/internal/editor/` 复制过来，CodeLook 构建时不再依赖 Lithe 仓库。

| 目录 | 内容 |
| --- | --- |
| `syntax/` | 语言表、内置 TextMate 语法（`grammars/`）、配色方案（`schemes/`）、高亮器 |
| `textmate/` | TextMate 分词器；`internal/regexp2` 是它用的正则引擎 |
| `rope/` | 文本缓冲区 |
| `editorperf/` | 只给测试和基准测试用的文本生成器 |

- **来源**：Lithe-IDEA `7667ebcd5f4e5ce526060d09a7786c4dbd13da90`（2026-11-25）。
- **复制时的改动**：只把导入路径从 `github.com/1lck/Lithe-IDEA/desktop/internal/editor/…` 换成了 `codelook/internal/…`，没有其他修改。
- **第三方许可**：语法文件、配色方案、`regexp2` 和 vscode-textmate 各自的许可证跟着文件一起放在对应目录里（`LICENSE.*`、`NOTICE*`、`ATTRIB`），再分发时要保留。

## 从 Lithe 同步

```sh
SRC=../Lithe-IDEA/desktop/internal/editor
for d in rope syntax textmate editorperf; do rsync -a --delete --exclude .DS_Store "$SRC/$d" Bridge/internal/; done
grep -rl 'github.com/1lck/Lithe-IDEA/desktop/internal/editor/' --include='*.go' Bridge/internal \
  | xargs sed -i '' 's#github.com/1lck/Lithe-IDEA/desktop/internal/editor/#codelook/internal/#g'
cd Bridge && go test ./... && cd .. && make test
```

同步后，记得更新上面的来源 commit。

`textmate/textmate_test.go` 里提到的 `scripts/desktop/generate-textmate-goldens.mjs` 在 Lithe 仓库里，用来重新生成 `textmate/testdata` 的对照结果。

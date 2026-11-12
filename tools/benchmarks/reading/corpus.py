"""Deterministic business documents; stored history is not visible body work."""
from dataclasses import dataclass
import hashlib


BODY_KIB = (8, 32, 128)
HISTORY_COUNTS = (1, 16, 64)


@dataclass(frozen=True)
class Corpus:
    execution: int
    target_bytes: int
    markdown: str
    anchors: tuple[str, ...]
    sections: int

    def manifest(self):
        encoded = self.markdown.encode("utf-8")
        return {"execution": self.execution, "targetBytes": self.target_bytes,
                "bytes": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest(),
                "sections": self.sections, "anchors": list(self.anchors),
                "contentKinds": ["headings", "paragraphs", "unicode", "inline-style",
                                 "list", "code", "table", "blockquote"]}


def document(execution, kib):
    if type(execution) is not int or not 1 <= execution <= 1000:
        raise ValueError("execution must be an integer in 1..1000")
    if type(kib) is not int or kib not in BODY_KIB:
        raise ValueError("body size must be 8, 32 or 128 KiB")
    parts = [f"# Reading review {execution:03d}\n\n"]
    anchors = []
    size = len(parts[0].encode("utf-8"))
    section = 0
    while size < kib * 1024:
        section += 1
        anchor = f"READ {execution:03d} SECTION {section:04d}"
        checkpoints = [f"READ {execution:03d} BLOCK {(section - 1) * 4 + n:04d}" for n in range(1, 5)]
        # Complete blocks retain the same composition at each scale. Truncating
        # bytes would change Markdown structure and can split a Unicode scalar.
        block = f"""## {anchor}

This review checks how a reader keeps a place while an agent reports its work.
The result should remain **readable**, *selectable*, and consistent after navigation.
The stage number is {section}; it identifies one independent part of the review.
检查窗口中的正文、历史目录和滚动位置。完成一段阅读之后，继续观察下一段内容。🌿

{checkpoints[0]}

- Open the existing document and read the recorded result.
- Scroll through the review without losing the selected execution.
- Return to the same history item and confirm its original content.

{checkpoints[1]}

```swift
struct ReviewRecord {{
    let section = {section}
    let observation = "Content remains available after returning."
    var complete: Bool {{ !observation.isEmpty }}
}}
```

{checkpoints[2]}

| Observation | Expected result |
| --- | --- |
| Document identity | The selected execution remains visible |
| Reading position | User scrolling owns the viewport |
| Final response | The complete result can be read |

{checkpoints[3]}

> The review records completed work. A quiet screen by itself does not prove
> either responsiveness or a failure; the expected action supplies that context.

"""
        parts.append(block)
        anchors.append(anchor)
        anchors.extend(checkpoints)
        size += len(block.encode("utf-8"))
    parts.append(f"READ {execution:03d} COMPLETE\n")
    return Corpus(execution, kib * 1024, "".join(parts), tuple(anchors), section)


def fixture_matrix(body_kib=BODY_KIB, history_counts=HISTORY_COUNTS):
    if (not body_kib or not history_counts or len(set(body_kib)) != len(body_kib)
            or len(set(history_counts)) != len(history_counts)):
        raise ValueError("nonempty, distinct workload levels are required")
    for kib in body_kib:
        document(1, kib)
    if any(type(count) is not int or count not in HISTORY_COUNTS for count in history_counts):
        raise ValueError("history levels must be 1, 16 or 64 executions")
    return sorted({(kib, 1) for kib in body_kib} | {(8, count) for count in history_counts})

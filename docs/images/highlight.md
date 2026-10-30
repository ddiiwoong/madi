## 구문 강조

```swift
/// 주석은 흐리게, 문자열과 키워드는 따로
struct Note: Codable {
    let title: String = "마디"
    var count = 42
}
```

```python
def greet(name: str) -> str:
    # 들여쓰기는 고정폭 그대로
    return f"안녕, {name}"
```

```yaml
title: 마디
tags: [편집기, 마크다운]
draft: false
```

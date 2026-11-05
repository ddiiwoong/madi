import AppKit
import ObjectiveC

/// 속성을 **고친 자리에서 바로** 고치는 텍스트 저장소 — 편집기가 쓴다.
///
/// **왜**(실측, 22만 자 문서): AppKit의 기본 저장소는 속성 고치기(글꼴에 없는 글자에 대체 글꼴을
/// 붙이는 일 — 시스템 글꼴의 한글이 그렇다)를 미뤄 두었다가 읽을 때 한다. 그런데 한 글자를 고치면
/// 그 **뒤의 전부**가 고칠 것으로 잡혀, 문서 앞쪽에서 한 글자를 칠 때마다 글리프 생성이
/// 65,536자를 두 번 고쳤다(`fixAttributes(in:)`을 가로채어 잼). 문서 끝에서는 남은 글이 짧아 싸서,
/// 같은 문서에서 앞쪽 5.7ms · 끝 2.3ms(앱에 든 글꼴), 앞쪽 15ms · 끝 3.4ms(시스템 글꼴)로 갈렸다.
///
/// 이 저장소는 미루지 않는다(`fixesAttributesLazily == false`). 그러면 `processEditing`이 고친
/// **문단만** 고치고, 글리프 생성은 이미 고쳐진 속성을 읽는다.
///
/// **속성 읽기는 Swift를 거치지 않는다.** `attributes(at:effectiveRange:)`를 Swift로 덮어쓰면
/// 레이아웃이 부를 때마다 속성 사전이 Objective-C ↔ Swift로 두 번 바뀐다(열쇠가 구조체라 지연
/// 변환이 안 된다) — 전체 레이아웃이 2.5배 느려졌다(128 → 324ms, sample에서 사전 만들기·해시가 위를
/// 차지). 그래서 그 셀렉터에는 **안의 저장소 구현을 그대로 넘기는** 블록을 붙인다(`installFastAccessors`).
final class EagerTextStorage: NSTextStorage {

    fileprivate let backing = NSMutableAttributedString()
    /// 글의 **불변** 사본. 고칠 때마다 만든다. 가변 문자열을 `String`으로 넘기면 통째로 복사되는데
    /// 레이아웃은 `string`을 수없이 묻는다. 불변 `NSString`은 감싸고 다시 꺼내도 같은 객체다.
    private var snapshot: NSString = ""

    override init() {
        Self.installFastAccessors
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("not used")
    }

    override var fixesAttributesLazily: Bool { false }

    override var string: String { snapshot as String }

    /// 지금까지 고친 글자 수. 테스트가 "한 글자를 치면 그 문단만 고친다"를 확인하는 데 쓴다.
    private(set) var fixedCharacterCount = 0

    override func fixAttributes(in range: NSRange) {
        fixedCharacterCount += range.length
        super.fixAttributes(in: range)
    }



    /// Swift 쪽 정의. 실제 호출은 아래에서 붙인 블록이 받는다 — 이것은 컴파일러가 요구하는 자리다.
    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func attribute(_ name: NSAttributedString.Key, at location: Int,
                            effectiveRange range: NSRangePointer?) -> Any? {
        backing.attribute(name, at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        snapshot = backing.mutableString.copy() as! NSString
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    // MARK: 빠른 읽기

    private typealias AttributesIMP = @convention(c) (AnyObject, Selector, Int, NSRangePointer?) -> NSDictionary
    private typealias AttributeIMP = @convention(c) (AnyObject, Selector, NSString, Int, NSRangePointer?) -> AnyObject?

    /// 두 읽기 셀렉터를, 안의 저장소 구현을 바로 부르는 블록으로 바꿔 끼운다. 한 번만 한다.
    private static let installFastAccessors: Void = {
        let inner: AnyClass = object_getClass(NSMutableAttributedString())!

        let attributesSelector = #selector(NSAttributedString.attributes(at:effectiveRange:))
        let innerAttributes = unsafeBitCast(class_getMethodImplementation(inner, attributesSelector),
                                            to: AttributesIMP.self)
        let attributesBlock: @convention(block) (EagerTextStorage, Int, NSRangePointer?) -> NSDictionary = {
            innerAttributes($0.backing, attributesSelector, $1, $2)
        }
        let attributesMethod = class_getInstanceMethod(EagerTextStorage.self, attributesSelector)!
        method_setImplementation(attributesMethod, imp_implementationWithBlock(attributesBlock))

        let attributeSelector = #selector(NSAttributedString.attribute(_:at:effectiveRange:))
        let innerAttribute = unsafeBitCast(class_getMethodImplementation(inner, attributeSelector),
                                           to: AttributeIMP.self)
        let attributeBlock: @convention(block) (EagerTextStorage, NSString, Int, NSRangePointer?) -> AnyObject? = {
            innerAttribute($0.backing, attributeSelector, $1, $2, $3)
        }
        let attributeMethod = class_getInstanceMethod(EagerTextStorage.self, attributeSelector)!
        method_setImplementation(attributeMethod, imp_implementationWithBlock(attributeBlock))
    }()
}

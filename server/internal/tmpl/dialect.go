package tmpl

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

const (
	MaxPatternRunes       = 512
	MaxCaptureGroups      = 8
	MaxBoundProduct       = 64
	MaxUnboundedPerBranch = 1
	MaxRepetitionWidth    = 1024
)

const (
	lenCap   = 1 << 30
	widthCap = MaxRepetitionWidth + 1
)

const (
	ReasonEmptyPattern                   = "empty_pattern"
	ReasonPatternTooLong                 = "pattern_too_long"
	ReasonTooManyCaptureGroups           = "too_many_capture_groups"
	ReasonEscapePerlSpace                = "escape_perl_space"
	ReasonEscapeWordBoundary             = "escape_word_boundary"
	ReasonEscapeUnicodeClass             = "escape_unicode_class"
	ReasonEscapeUnicodeCodepoint         = "escape_unicode_codepoint"
	ReasonEscapeTextAnchor               = "escape_text_anchor"
	ReasonEscapeBackreference            = "escape_backreference"
	ReasonEscapeNotAllowed               = "escape_not_allowed"
	ReasonMalformedEscape                = "malformed_escape"
	ReasonInlineFlags                    = "inline_flags"
	ReasonLookaround                     = "lookaround"
	ReasonNamedGroupJSSyntax             = "named_group_js_syntax"
	ReasonUnsupportedGroup               = "unsupported_group"
	ReasonInvalidGroupName               = "invalid_group_name"
	ReasonDuplicateGroupName             = "duplicate_group_name"
	ReasonUnbalancedParen                = "unbalanced_paren"
	ReasonBareDot                        = "bare_dot"
	ReasonGroupUnboundedQuantifier       = "group_unbounded_quantifier"
	ReasonUnboundedInsideQuantifiedGroup = "unbounded_inside_quantified_group"
	ReasonMultipleUnboundedQuantifiers   = "multiple_unbounded_quantifiers"
	ReasonNestedVariableRepetition       = "nested_variable_repetition"
	ReasonRepetitionWidthTooLarge        = "repetition_width_too_large"
	ReasonBoundProductTooLarge           = "bound_product_too_large"
	ReasonMalformedRepetition            = "malformed_repetition"
	ReasonEmptyCharClass                 = "empty_character_class"
	ReasonUnterminatedCharClass          = "unterminated_character_class"
	ReasonClassLiteralBracket            = "class_literal_bracket"
	ReasonFlagNotAllowed                 = "flag_not_allowed"
	ReasonDuplicateFlag                  = "duplicate_flag"
	ReasonNotCompilable                  = "not_compilable"
)

func AllReasonCodes() []string {
	return []string{
		ReasonEmptyPattern, ReasonPatternTooLong, ReasonTooManyCaptureGroups,
		ReasonEscapePerlSpace, ReasonEscapeWordBoundary, ReasonEscapeUnicodeClass,
		ReasonEscapeUnicodeCodepoint, ReasonEscapeTextAnchor, ReasonEscapeBackreference,
		ReasonEscapeNotAllowed, ReasonMalformedEscape, ReasonInlineFlags, ReasonLookaround,
		ReasonNamedGroupJSSyntax, ReasonUnsupportedGroup, ReasonInvalidGroupName,
		ReasonDuplicateGroupName, ReasonUnbalancedParen, ReasonBareDot,
		ReasonGroupUnboundedQuantifier, ReasonUnboundedInsideQuantifiedGroup,
		ReasonMultipleUnboundedQuantifiers, ReasonNestedVariableRepetition, ReasonRepetitionWidthTooLarge,
		ReasonBoundProductTooLarge, ReasonMalformedRepetition, ReasonEmptyCharClass,
		ReasonUnterminatedCharClass, ReasonClassLiteralBracket, ReasonFlagNotAllowed,
		ReasonDuplicateFlag, ReasonNotCompilable,
	}
}

type PatternError struct {
	Code    string
	Offset  int
	Message string
}

func (e *PatternError) Error() string {
	return fmt.Sprintf("%s at %d: %s", e.Code, e.Offset, e.Message)
}

func Codes(errs []error) []string {
	out := make([]string, 0, len(errs))
	for _, err := range errs {
		var pe *PatternError
		if errors.As(err, &pe) {
			out = append(out, pe.Code)
			continue
		}
		out = append(out, err.Error())
	}
	return out
}

const escapeWhitelist = `nrtfv` + `dDwW` + `\.+*?()[]{}|^$/`

const escapeClassOnly = `-`

var groupNameRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func ValidatePattern(p string, flags []string) []error {
	v := &patternScanner{src: []rune(p)}
	v.checkFlags(flags)
	v.scan()
	if len(v.errs) == 0 {
		if _, err := CompileGo(p, flags); err != nil {
			v.add(0, ReasonNotCompilable, "does not compile in Go RE2: "+err.Error())
		}
	}
	return v.errs
}

func CompileGo(p string, flags []string) (*regexp.Regexp, error) {
	prefix := ""
	for _, f := range flags {
		if f == "i" {
			prefix = "(?i)"
		}
	}
	return regexp.Compile(prefix + p)
}

func ToJS(p string) string {
	r := []rune(p)
	var b strings.Builder
	b.Grow(len(p))
	inClass := false
	for i := 0; i < len(r); i++ {
		c := r[i]
		if c == '\\' {
			b.WriteRune(c)
			if i+1 < len(r) {
				i++
				b.WriteRune(r[i])
			}
			continue
		}
		if inClass {
			if c == ']' {
				inClass = false
			}
			b.WriteRune(c)
			continue
		}
		switch {
		case c == '[':
			inClass = true
			b.WriteRune(c)
		case c == '(' && i+3 < len(r) && r[i+1] == '?' && r[i+2] == 'P' && r[i+3] == '<':
			b.WriteString("(?<")
			i += 3
		default:
			b.WriteRune(c)
		}
	}
	return b.String()
}

type frame struct {
	hasUnbounded    bool
	best            int
	branchUnbounded int
	maxUnbounded    int

	branchMin, branchMax int
	min, max             int
	folded               bool
	branchWidth, width   int
}

func newFrame() *frame { return &frame{best: 1, branchWidth: 1} }

func (f *frame) endBranch() {
	f.maxUnbounded = f.worstBranch()
	f.branchUnbounded = 0
	if !f.folded || f.branchMin < f.min {
		f.min = f.branchMin
	}
	if f.branchMax > f.max {
		f.max = f.branchMax
	}
	f.folded = true
	f.width = satAdd(f.width, f.branchWidth)
	f.branchMin, f.branchMax, f.branchWidth = 0, 0, 1
}

func (f *frame) variable() bool { return f.min != f.max }

func (f *frame) worstBranch() int {
	if f.branchUnbounded > f.maxUnbounded {
		return f.branchUnbounded
	}
	return f.maxUnbounded
}

type patternScanner struct {
	src      []rune
	errs     []error
	stack    []*frame
	captures int
	names    map[string]bool
	reported map[string]bool
}

func (v *patternScanner) add(offset int, code, msg string) {
	if v.reported == nil {
		v.reported = map[string]bool{}
	}
	key := code + "@" + strconv.Itoa(offset)
	if v.reported[key] {
		return
	}
	v.reported[key] = true
	v.errs = append(v.errs, &PatternError{Code: code, Offset: offset, Message: msg})
}

func (v *patternScanner) addOnce(offset int, code, msg string) {
	if v.reported == nil {
		v.reported = map[string]bool{}
	}
	if v.reported["once:"+code] {
		return
	}
	v.reported["once:"+code] = true
	v.errs = append(v.errs, &PatternError{Code: code, Offset: offset, Message: msg})
}

func (v *patternScanner) checkFlags(flags []string) {
	seen := map[string]bool{}
	for i, f := range flags {
		switch {
		case f != "i":
			v.add(i, ReasonFlagNotAllowed, fmt.Sprintf("flag %q is not permitted; only \"i\" is", f))
		case seen[f]:
			v.add(i, ReasonDuplicateFlag, fmt.Sprintf("flag %q is listed more than once", f))
		}
		seen[f] = true
	}
}

func (v *patternScanner) top() *frame { return v.stack[len(v.stack)-1] }

func (v *patternScanner) scan() {
	if len(v.src) == 0 {
		v.add(0, ReasonEmptyPattern, "a pattern must not be empty")
		return
	}
	if len(v.src) > MaxPatternRunes {
		v.add(MaxPatternRunes, ReasonPatternTooLong,
			fmt.Sprintf("pattern is %d runes; the limit is %d", len(v.src), MaxPatternRunes))
		return
	}

	v.stack = []*frame{newFrame()}
	i := 0
	for i < len(v.src) {
		switch c := v.src[i]; {
		case c == '\\':
			i = v.quantify(v.escape(i, false), atomSimple, nil)
		case c == '[':
			i = v.quantify(v.charClass(i), atomSimple, nil)
		case c == '(':
			i = v.openGroup(i)
		case c == ')':
			if len(v.stack) == 1 {
				v.add(i, ReasonUnbalancedParen, "')' with no matching '('")
				i++
				continue
			}
			child := v.stack[len(v.stack)-1]
			v.stack = v.stack[:len(v.stack)-1]
			child.endBranch()
			i = v.quantify(i+1, atomGroup, child)
		case c == '.':
			v.add(i, ReasonBareDot, `a bare '.' matches \r, U+2028 and U+2029 in Go but not in JavaScript; write [^\n]`)
			i = v.quantify(i+1, atomSimple, nil)
		case c == '*' || c == '+' || c == '?':
			v.add(i, ReasonMalformedRepetition, fmt.Sprintf("'%c' has no atom to repeat", c))
			i++
		case c == '{':
			v.add(i, ReasonMalformedRepetition, `a literal '{' must be written \{`)
			i++
		case c == '|':
			v.top().endBranch()
			i++
		case c == '^' || c == '$':
			i++
		default:
			i = v.quantify(i+1, atomSimple, nil)
		}
	}

	if len(v.stack) > 1 {
		v.add(len(v.src), ReasonUnbalancedParen,
			fmt.Sprintf("%d group(s) left open", len(v.stack)-1))
	}
	root := v.stack[0]
	root.endBranch()
	if root.best > MaxBoundProduct {
		v.addOnce(0, ReasonBoundProductTooLarge,
			fmt.Sprintf("the product of {n,m} upper bounds along one nesting path is %d; the limit is %d",
				root.best, MaxBoundProduct))
	}
	if root.width > MaxRepetitionWidth {
		v.addOnce(0, ReasonRepetitionWidthTooLarge,
			fmt.Sprintf("one alternation branch can split the same input %d different ways; the limit is %d. "+
				"That is the number of paths a BACKTRACKING engine can try before it gives up, and it is not "+
				"what MaxBoundProduct measures: eight sibling [a-z]{1,8} runs nest nothing and quantify no "+
				"group, and took 7,140 ms on a 512-character body in Bun 1.3.14. Collapse adjacent runs — "+
				"(?:X{1,4}){8} is X{8,32} — or make them fixed-width",
				root.width, MaxRepetitionWidth))
	}
}

type atomKind int

const (
	atomSimple atomKind = iota
	atomGroup
)

func (v *patternScanner) quantify(next int, kind atomKind, child *frame) int {
	q, after := v.readQuant(next)
	cur := v.top()

	childBest, childUnbounded := 1, false
	if child != nil {
		childBest, childUnbounded = child.best, child.hasUnbounded
	}

	if q.present && kind == atomGroup {
		if q.unbounded {
			v.add(next, ReasonGroupUnboundedQuantifier,
				"an unbounded quantifier on a group is the catastrophic-backtracking shape; "+
					"'?' and '{n,m}' are bounded and are allowed")
		} else if childUnbounded {
			v.add(next, ReasonUnboundedInsideQuantifiedGroup,
				"this group is quantified and contains an unbounded quantifier; "+
					"that is the (a+)+ nesting — bound the inner quantifier with {n,m}")
		}
	}

	if child != nil && q.present && !q.unbounded && q.max >= 2 && child.variable() {
		v.add(next, ReasonNestedVariableRepetition,
			fmt.Sprintf("this group repeats up to %d times and its contents match between %d and %d runes; "+
				"a variable-length repetition inside a repetition is exponential in the repeat count in a "+
				"BACKTRACKING engine, which RE2 is not and the device's is. MEASURED in Bun 1.3.14 on a "+
				"512-rune subject: (?:[a-z0-9 ]{1,8}){8}z is 2,178 ms and (?:(?:[a-z]{1,4}){4}){4}z is "+
				"1,948 ms, while (?:[a-z]{8}){8}z — same bound product, fixed-width interior — is 0.0 ms. "+
				"Collapse it: (?:X{1,4}){8} is X{8,32}",
				q.max, child.min, child.max))
	}

	if q.present && q.unbounded {
		cur.hasUnbounded = true
	}
	if childUnbounded {
		cur.hasUnbounded = true
	}

	added := 0
	if q.present && q.unbounded {
		added++
	}
	if child != nil {
		added += child.worstBranch()
	}
	if added > 0 {
		cur.branchUnbounded += added
		if cur.branchUnbounded > MaxUnboundedPerBranch {
			v.addOnce(next, ReasonMultipleUnboundedQuantifiers,
				fmt.Sprintf("more than %d unbounded quantifier in one alternation branch: that is the "+
					"POLYNOMIAL backtracking shape (n^k for k of them), which RE2 is immune to and "+
					"JavaScript is not. Collapse them — [0-9]+[0-9]+ is [0-9]{2,} — or bound all but one with {n,m}",
					MaxUnboundedPerBranch))
		}
	}

	prod := childBest
	if q.present && !q.unbounded {
		prod = mulCapped(childBest, q.max)
	}
	if prod > cur.best {
		cur.best = prod
	}

	atomMin, atomMax, atomWidth := 1, 1, 1
	if child != nil {
		atomMin, atomMax, atomWidth = child.min, child.max, child.width
	}
	addMin, addMax, addWidth := atomMin, atomMax, atomWidth
	if q.present {
		if q.unbounded {
			addMin, addMax = satMul(q.min, atomMin), lenCap
		} else {
			addMin, addMax = satMul(q.min, atomMin), satMul(q.max, atomMax)
			addWidth = satMul(satPow(atomWidth, q.max), q.max-q.min+1)
		}
	}
	cur.branchMin = satAdd(cur.branchMin, addMin)
	cur.branchMax = satAdd(cur.branchMax, addMax)
	cur.branchWidth = satMul(cur.branchWidth, addWidth)
	return after
}

func satAdd(a, b int) int {
	if s := a + b; s <= lenCap {
		return s
	}
	return lenCap
}

func satMul(a, b int) int {
	if a == 0 || b == 0 {
		return 0
	}
	if a > lenCap/b {
		return lenCap
	}
	return a * b
}

func satPow(a, n int) int {
	if a <= 1 {
		if a == 0 {
			return 0
		}
		return 1
	}
	out := 1
	for k := 0; k < n; k++ {
		if out > widthCap/a {
			return widthCap
		}
		out *= a
		if out > widthCap {
			return widthCap
		}
	}
	return out
}

func mulCapped(a, b int) int {
	if a > MaxBoundProduct || b > MaxBoundProduct {
		return MaxBoundProduct + 1
	}
	p := a * b
	if p > MaxBoundProduct {
		return MaxBoundProduct + 1
	}
	return p
}

type quant struct {
	present   bool
	unbounded bool
	min, max  int
}

func (v *patternScanner) readQuant(i int) (quant, int) {
	if i >= len(v.src) {
		return quant{}, i
	}
	switch v.src[i] {
	case '*':
		return quant{present: true, unbounded: true, min: 0}, v.skipLazy(i + 1)
	case '+':
		return quant{present: true, unbounded: true, min: 1}, v.skipLazy(i + 1)
	case '?':
		return quant{present: true, min: 0, max: 1}, v.skipLazy(i + 1)
	case '{':
		return v.readBraceQuant(i)
	}
	return quant{}, i
}

func (v *patternScanner) skipLazy(i int) int {
	if i < len(v.src) && v.src[i] == '?' {
		return i + 1
	}
	return i
}

func (v *patternScanner) readBraceQuant(i int) (quant, int) {
	j := i + 1
	start := j
	for j < len(v.src) && v.src[j] >= '0' && v.src[j] <= '9' {
		j++
	}
	if j == start {
		v.add(i, ReasonMalformedRepetition, `'{' must open a repetition {n}, {n,} or {n,m}; a literal '{' is written \{`)
		return quant{}, i + 1
	}
	lo, err := strconv.Atoi(string(v.src[start:j]))
	if err != nil {
		v.add(i, ReasonMalformedRepetition, "repetition count is not a number")
		return quant{}, i + 1
	}
	if j < len(v.src) && v.src[j] == '}' {
		return quant{present: true, min: lo, max: lo}, v.skipLazy(j + 1)
	}
	if j >= len(v.src) || v.src[j] != ',' {
		v.add(i, ReasonMalformedRepetition, "unterminated repetition")
		return quant{}, i + 1
	}
	j++
	hiStart := j
	for j < len(v.src) && v.src[j] >= '0' && v.src[j] <= '9' {
		j++
	}
	if j >= len(v.src) || v.src[j] != '}' {
		v.add(i, ReasonMalformedRepetition, "unterminated repetition")
		return quant{}, i + 1
	}
	if hiStart == j {
		return quant{present: true, unbounded: true, min: lo}, v.skipLazy(j + 1)
	}
	hi, err := strconv.Atoi(string(v.src[hiStart:j]))
	if err != nil {
		v.add(i, ReasonMalformedRepetition, "repetition count is not a number")
		return quant{}, i + 1
	}
	if hi < lo {
		v.add(i, ReasonMalformedRepetition, fmt.Sprintf("repetition {%d,%d} counts down", lo, hi))
		return quant{}, v.skipLazy(j + 1)
	}
	return quant{present: true, min: lo, max: hi}, v.skipLazy(j + 1)
}

func (v *patternScanner) escape(i int, inClass bool) int {
	if i+1 >= len(v.src) {
		v.add(i, ReasonMalformedEscape, "pattern ends with a backslash")
		return i + 1
	}
	c := v.src[i+1]
	switch {
	case c == 's' || c == 'S':
		v.add(i, ReasonEscapePerlSpace,
			`\s is [\t\n\f\r ] in Go; in JavaScript it also matches \v, U+00A0, U+FEFF and the Unicode space separators. `+
				`On normalized text write the exact set, e.g. [ \n]`)
	case c == 'b' || c == 'B':
		v.add(i, ReasonEscapeWordBoundary,
			`word boundaries diverge once the i flag is set (JavaScript's word set gains U+017F and U+212A, Go's does not) `+
				`and are meaningless around Arabic, which this corpus is`)
	case c == 'p' || c == 'P':
		v.add(i, ReasonEscapeUnicodeClass,
			`Go spells it \p{Arabic} and JavaScript spells it \p{Script=Arabic}; neither engine accepts the other's form`)
	case c == 'u':
		v.add(i, ReasonEscapeUnicodeCodepoint, `\u{...} does not compile in Go; write the character itself or \xHH`)
	case c == 'x':
		return v.hexEscape(i)
	case c == 'A' || c == 'z' || c == 'Z':
		v.add(i, ReasonEscapeTextAnchor, `\A, \z and \Z compile in Go and are a SyntaxError in JavaScript; use ^ and $`)
	case c >= '0' && c <= '9':
		v.add(i, ReasonEscapeBackreference,
			"backreferences and octal escapes: RE2 has neither, and a backreference has unbounded cost in JavaScript")
	case c == 'k':
		v.add(i, ReasonEscapeBackreference, `\k is a named backreference in JavaScript and not supported in RE2`)
	case strings.ContainsRune(escapeWhitelist, c):
	case inClass && strings.ContainsRune(escapeClassOnly, c):
	default:
		v.add(i, ReasonEscapeNotAllowed,
			fmt.Sprintf(`\%c is not in the dialect's escape whitelist; the two engines were not measured to agree on it`, c))
	}
	return i + 2
}

func (v *patternScanner) hexEscape(i int) int {
	if i+2 < len(v.src) && v.src[i+2] == '{' {
		v.add(i, ReasonEscapeUnicodeCodepoint, `\x{...} is a SyntaxError in JavaScript under the u flag; write \xHH or the character itself`)
		for j := i + 2; j < len(v.src); j++ {
			if v.src[j] == '}' {
				return j + 1
			}
		}
		return len(v.src)
	}
	if i+3 >= len(v.src) || !isHex(v.src[i+2]) || !isHex(v.src[i+3]) {
		v.add(i, ReasonMalformedEscape, `\x must be followed by exactly two hexadecimal digits`)
		return i + 2
	}
	return i + 4
}

func isHex(r rune) bool {
	return (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')
}

func (v *patternScanner) charClass(i int) int {
	j := i + 1
	if j < len(v.src) && v.src[j] == '^' {
		j++
	}
	if j < len(v.src) && v.src[j] == ']' {
		v.add(i, ReasonEmptyCharClass, `an empty character class; a literal ']' is written \]`)
		return j + 1
	}
	for j < len(v.src) {
		switch v.src[j] {
		case '\\':
			j = v.escape(j, true)
		case '[':
			v.add(j, ReasonClassLiteralBracket,
				`a '[' inside a character class must be written \[: Go reads [[:alpha:]] as a POSIX class `+
					`and JavaScript under the u flag makes it a SyntaxError`)
			j++
		case ']':
			return j + 1
		default:
			j++
		}
	}
	v.add(i, ReasonUnterminatedCharClass, "character class is never closed")
	return len(v.src)
}

func (v *patternScanner) openGroup(i int) int {
	push := func(next int) int {
		v.stack = append(v.stack, newFrame())
		return next
	}
	capture := func() {
		v.captures++
		if v.captures > MaxCaptureGroups {
			v.addOnce(i, ReasonTooManyCaptureGroups,
				fmt.Sprintf("more than %d capture groups", MaxCaptureGroups))
		}
	}

	if i+1 >= len(v.src) || v.src[i+1] != '?' {
		capture()
		return push(i + 1)
	}
	if i+2 >= len(v.src) {
		v.add(i, ReasonUnsupportedGroup, "'(?' is not a group")
		return push(i + 2)
	}

	switch v.src[i+2] {
	case ':':
		return push(i + 3)
	case '=', '!':
		v.add(i, ReasonLookaround, "lookahead is a backtracking construct and RE2 has no equivalent")
		return push(i + 3)
	case '<':
		if i+3 < len(v.src) && (v.src[i+3] == '=' || v.src[i+3] == '!') {
			v.add(i, ReasonLookaround, "lookbehind is a backtracking construct and RE2 has no equivalent")
			return push(i + 4)
		}
		v.add(i, ReasonNamedGroupJSSyntax,
			"a named group is stored as (?P<name>...) and rewritten to (?<name>...) for JavaScript by ToJS; "+
				"storing the JavaScript spelling would not compile in Go RE2 before Go 1.22 and defeats the single-stored-text rule")
		return push(i + 3)
	case 'P':
		if i+3 < len(v.src) && v.src[i+3] == '<' {
			capture()
			return push(v.groupName(i + 4))
		}
		v.add(i, ReasonUnsupportedGroup, "(?P= and (?P> are not part of the dialect")
		return push(i + 3)
	case '#':
		v.add(i, ReasonUnsupportedGroup, "(?# comments are not part of the dialect")
		return push(i + 3)
	default:
		v.add(i, ReasonInlineFlags,
			"JavaScript has no inline flag groups; declare flags on the Extract entry instead")
		return push(i + 3)
	}
}

func (v *patternScanner) groupName(i int) int {
	j := i
	for j < len(v.src) && v.src[j] != '>' {
		j++
	}
	if j >= len(v.src) {
		v.add(i, ReasonInvalidGroupName, "group name is never closed with '>'")
		return len(v.src)
	}
	name := string(v.src[i:j])
	if !groupNameRe.MatchString(name) {
		v.add(i, ReasonInvalidGroupName,
			fmt.Sprintf("group name %q must match [A-Za-z_][A-Za-z0-9_]*: Go accepts names JavaScript rejects "+
				"(a leading digit) and JavaScript accepts names Go rejects (a '$')", name))
	}
	if v.names == nil {
		v.names = map[string]bool{}
	}
	if v.names[name] {
		v.add(i, ReasonDuplicateGroupName,
			fmt.Sprintf("group name %q is used twice; Go allows this and JavaScript rejects it", name))
	}
	v.names[name] = true
	return j + 1
}

func GroupNames(p string) []string {
	re, err := regexp.Compile(p)
	if err != nil {
		return nil
	}
	var out []string
	for _, n := range re.SubexpNames() {
		if n != "" {
			out = append(out, n)
		}
	}
	return out
}

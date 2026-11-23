package tmpl

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func codesOf(errs []error) []string { return Codes(errs) }

func hasCode(errs []error, code string) bool {
	for _, c := range codesOf(errs) {
		if c == code {
			return true
		}
	}
	return false
}

type dialectRule struct {
	code         string
	reject       string
	rejectFlags  []string
	accept       string
	acceptFlags  []string
	divergence   string
	rejectIsLong bool
}

func dialectRules() []dialectRule {
	long := strings.Repeat("a", MaxPatternRunes+1)
	ok := strings.Repeat("a", MaxPatternRunes)
	nine := strings.Repeat("(a)", MaxCaptureGroups+1)
	eight := strings.Repeat("(a)", MaxCaptureGroups)

	return []dialectRule{
		{code: ReasonEmptyPattern, reject: ``, accept: `a`,
			divergence: "an empty pattern matches everything; never intended"},
		{code: ReasonPatternTooLong, reject: long, accept: ok, rejectIsLong: true,
			divergence: "bounded cost"},
		{code: ReasonTooManyCaptureGroups, reject: nine, accept: eight, rejectIsLong: true,
			divergence: "bounded cost"},
		{code: ReasonEscapePerlSpace, reject: `AED\s+([0-9]+)`, accept: `AED[ \n]{1,4}([0-9]+)`,
			divergence: `Go \s is [\t\n\f\r ]; JS \s additionally matches \v, U+00A0, U+FEFF and the Unicode space separators`},
		{code: ReasonEscapeWordBoundary, reject: `\bAED\b`, accept: `AED`,
			divergence: `with the i flag JS's word set gains U+017F and U+212A, Go's does not: (?i)\bk vs /\bk/iu on U+212A is false in Go, true in JS`},
		{code: ReasonEscapeUnicodeClass, reject: `\p{Arabic}`, accept: `[\x41-\x5a]`,
			divergence: `Go accepts \p{Arabic} and rejects \p{Script=Arabic}; JS under u does the exact opposite`},
		{code: ReasonEscapeUnicodeCodepoint, reject: `\x{0623}`, accept: `\x41`,
			divergence: `\x{...} is a SyntaxError in JS under u; \u{...} does not compile in Go`},
		{code: ReasonEscapeTextAnchor, reject: `\Ax`, accept: `^x`,
			divergence: `\A, \z and \Z compile in Go and are a SyntaxError in JS`},
		{code: ReasonEscapeBackreference, reject: `(a)\1`, accept: `(a)a`,
			divergence: "backreferences are absent from RE2 and unbounded in JS"},
		{code: ReasonEscapeNotAllowed, reject: `\a`, accept: `\t`,
			divergence: `\a is BEL in Go and a SyntaxError in JS under u; the escape set is a whitelist, so every such escape is caught, not only the named ones`},
		{code: ReasonMalformedEscape, reject: `a\`, accept: `a\\`,
			divergence: "a trailing backslash is not a pattern"},
		{code: ReasonInlineFlags, reject: `(?i)aed`, accept: `aed`, acceptFlags: []string{"i"},
			divergence: "JS has no inline flag groups; declare flags on the Extract entry"},
		{code: ReasonLookaround, reject: `(?=x)`, accept: `x`,
			divergence: "lookaround is a backtracking construct and RE2 lacks it"},
		{code: ReasonNamedGroupJSSyntax, reject: `(?<amt>[0-9])`, accept: `(?P<amt>[0-9])`,
			divergence: "one stored spelling only, so ToJS is total and the stored text is what Go runs"},
		{code: ReasonUnsupportedGroup, reject: `(?P=amt)`, accept: `(?P<amt>[0-9])`,
			divergence: "(?P=, (?P> and (?# exist in Go or PCRE and not in JS"},
		{code: ReasonInvalidGroupName, reject: `(?P<0a>x)`, accept: `(?P<a0>x)`,
			divergence: `Go accepts (?P<0a>...); JS under u rejects it. Go rejects (?<a$b>...); JS accepts it`},
		{code: ReasonDuplicateGroupName, reject: `(?P<v>a)(?P<v>b)`, accept: `(?P<v>a)(?P<w>b)`,
			divergence: "Go accepts duplicate capture names, JS rejects them"},
		{code: ReasonUnbalancedParen, reject: `(a`, accept: `(a)`,
			divergence: "structural"},
		{code: ReasonBareDot, reject: `Debit Amount:\n(.+)`, accept: `Debit Amount:\n([^\n]+)`,
			divergence: `Go's . matches \r, U+2028 and U+2029; JS's does not`},
		{code: ReasonGroupUnboundedQuantifier, reject: `(ab)+c`, accept: `(ab)?c`,
			divergence: "an unbounded quantifier on a group is the catastrophic-backtracking shape"},
		{code: ReasonUnboundedInsideQuantifiedGroup, reject: `([0-9]+)?`, accept: `([0-9]{1,4})?`,
			divergence: "(a+)+ nesting turns bounded work exponential in a backtracking engine"},
		{code: ReasonMultipleUnboundedQuantifiers, reject: `[0-9]+[0-9]+z`, accept: `[0-9]{2,}z`,
			divergence: "the POLYNOMIAL backtracking shape: n^k for k unbounded quantifiers that can consume " +
				"the same characters. MEASURED in Bun 1.3.14: [0-9]+[0-9]+z is 86 ms on 800 characters, " +
				"[0-9]+[0-9]+[0-9]+[0-9]+z is 88,191 ms on 400, and separating them with a mandatory literal " +
				"does not help ([^\\n]+X[^\\n]+Y is 31,680 ms on 8,000). Go's RE2 does not backtrack and is " +
				"unaffected, so this is a CLIENT-side cost rule, not an engine divergence"},
		{code: ReasonNestedVariableRepetition, reject: `(?:[0-9]{1,4}){4}`, accept: `[0-9]{4,16}`,
			divergence: "the BOUNDED analogue of unbounded_inside_quantified_group, and the hole it left: a " +
				"group that repeats more than once re-splits its own contents on every repeat, so a " +
				"variable-length interior is raised to the power of the repeat count. MEASURED in Bun 1.3.14 " +
				"on a 512-rune subject: (?:[a-z0-9 ]{1,8}){8}z is 2,178 ms and (?:(?:[a-z]{1,4}){4}){4}z is " +
				"1,948 ms, while (?:[a-z]{8}){8}z — the SAME bound product of 64, fixed-width interior — is " +
				"0.0 ms, which is why no tightening of MaxBoundProduct separates them. '?' and {0,1} are " +
				"exempt: one repetition multiplies nothing, and ([0-9]{1,4})? is this table's own rewrite for " +
				"([0-9]+)?. RE2 does not backtrack, so this is a client-side cost rule"},
		{code: ReasonRepetitionWidthTooLarge, reject: `[0-9]{1,16}[0-9]{1,16}[0-9]{1,16}z`, accept: `[0-9]{3,48}z`,
			divergence: "the same explosion reached by CONCATENATION rather than nesting, which no nesting " +
				"rule can see: three sibling runs nest nothing and quantify no group. MEASURED in Bun 1.3.14: " +
				"eight sibling [a-z]{1,8} runs took 7,140 ms on a 512-character body, and " +
				"[0-9]{1,64}[0-9]{1,64}z took 8,711 ms at MaxBodyBytes (2,000,000 digits) — measured there, " +
				"not extrapolated from a smaller run. The bound is the number of ways one branch can split " +
				"the same input, which is what MaxBoundProduct (a bound on match LENGTH) does not measure. " +
				"1,024 is exactly the widest collapsible pair MaxBoundProduct still permits: {1,a}{1,b} " +
				"collapses to {2,a+b}, a+b <= 64 maximises a*b at 32*32; the widest pattern the seed set " +
				"actually ships is 200, and the widest this rule ADMITS still costs 1,858 ms at MaxBodyBytes"},
		{code: ReasonBoundProductTooLarge, reject: `((a{4}){4}){5}`, accept: `((a{4}){4}){4}`,
			divergence: "bounded match length"},
		{code: ReasonMalformedRepetition, reject: `a{,3}`, accept: `a{0,3}`,
			divergence: "Go reads a{,3} as five literal characters; JS under u makes it a SyntaxError"},
		{code: ReasonEmptyCharClass, reject: `[]`, accept: `[a]`,
			divergence: "Go rejects []; JS under u reads it as a class that never matches"},
		{code: ReasonUnterminatedCharClass, reject: `[abc`, accept: `[abc]`,
			divergence: "structural"},
		{code: ReasonClassLiteralBracket, reject: `[[:alpha:]]`, accept: `[a-zA-Z]`,
			divergence: "Go compiles [[:alpha:]] as a POSIX class; JS under u makes it a SyntaxError, and without u it silently means something else"},
		{code: ReasonFlagNotAllowed, reject: `x`, rejectFlags: []string{"m"}, accept: `x`, acceptFlags: []string{"i"},
			divergence: `JS's m treats \r, U+2028 and U+2029 as line terminators for ^/$ and Go's does not`},
		{code: ReasonDuplicateFlag, reject: `x`, rejectFlags: []string{"i", "i"}, accept: `x`, acceptFlags: []string{"i"},
			divergence: "a flag list is a set; a repeat is an authoring mistake"},
		{code: ReasonNotCompilable, reject: `[z-a]`, accept: `[a-z]`,
			divergence: "the structural scanner is not a parser; Go's own compiler is the backstop"},
	}
}

func TestEveryDialectRuleRejectsItsConstructAndAcceptsItsRewrite(t *testing.T) {
	seen := map[string]bool{}
	for _, r := range dialectRules() {
		if seen[r.code] {
			t.Errorf("duplicate rule code %q in the table", r.code)
		}
		seen[r.code] = true

		errs := ValidatePattern(r.reject, r.rejectFlags)
		if !hasCode(errs, r.code) {
			name := r.reject
			if r.rejectIsLong {
				name = "<generated>"
			}
			t.Errorf("rule %s: pattern %q flags %v must be rejected with that code, got %v",
				r.code, name, r.rejectFlags, codesOf(errs))
		}

		if errs := ValidatePattern(r.accept, r.acceptFlags); len(errs) != 0 {
			name := r.accept
			if r.rejectIsLong {
				name = "<generated>"
			}
			t.Errorf("rule %s: sanctioned rewrite %q flags %v must be accepted, got %v",
				r.code, name, r.acceptFlags, codesOf(errs))
		}
	}

	for _, c := range AllReasonCodes() {
		if !seen[c] {
			t.Errorf("reason code %q is defined but has no row in the dialect table (so it has no accept/reject pair)", c)
		}
	}
}

func TestValidatePatternRejectsTheDivergentAndUnsafeConstructs(t *testing.T) {
	for _, p := range []string{
		`AED\s+([0-9]+)`, `\bAED\b`, `(?i)aed`, `(?=x)`, `(a)\1`,
		`\p{Arabic}`, `\x{0623}`, `\Ax`,
		`(ab)+c`, `(ab)*c`, `(ab){2,}c`,
		`([0-9]+)?`, `(a|b*)?`,
		`Debit Amount:\n(.+)`,
		strings.Repeat("a", MaxPatternRunes+1),
	} {
		if errs := ValidatePattern(p, nil); len(errs) == 0 {
			t.Errorf("pattern %q must be rejected", p)
		}
	}
	if errs := ValidatePattern(`x`, []string{"m"}); len(errs) == 0 {
		t.Error(`flag "m" must be rejected`)
	}
}

func TestValidatePatternAcceptsTheSeedShapes(t *testing.T) {
	for _, p := range []string{
		`المبلغ\n(?P<ccy>[A-Z]{3} )?(?P<amt>[0-9][0-9,]{0,24}\.[0-9]{2})`,
		`Debit Amount:\n(?P<amt>[^\n]+)`,
		`account ending with (?P<v>[0-9]{4})`,
		`بتاريخ (?P<d>[0-9]{2}-[0-9]{2}-[0-9]{4})`,
		`(?P<amt>(?:[A-Z]{3} )?[0-9][0-9,]{0,24}\.[0-9]{2})[ \n]has been[ \n](?:withdrawn|debited|deducted)[ \n]from your account`,
	} {
		if errs := ValidatePattern(p, nil); len(errs) != 0 {
			t.Errorf("pattern %q rejected: %v", p, errs)
		}
	}
}

func TestValidatePatternAcceptsTheSeedShapesUnderTheIFlag(t *testing.T) {
	for _, p := range []string{
		`(?P<amt>(?:[A-Z]{3} )?[0-9][0-9,]{0,24}\.[0-9]{2})[ \n]has been[ \n](?:credited|deposited)[ \n](?:in)?to your account`,
		`account ending with (?P<v>[0-9]{4})`,
		`DEBIT$`,
	} {
		if errs := ValidatePattern(p, []string{"i"}); len(errs) != 0 {
			t.Errorf("pattern %q with flags [i] rejected: %v", p, errs)
		}
	}
}

func TestBoundedQuantifiersOnAGroupAreAllowedAndUnboundedOnesAreNot(t *testing.T) {
	for _, p := range []string{`(ab)?`, `(ab){2,3}`, `(ab){3}`, `(?:[A-Z]{3} )?`, `(?P<ccy>[A-Z]{3} )?`} {
		if errs := ValidatePattern(p, nil); len(errs) != 0 {
			t.Errorf("bounded group quantifier %q must be allowed: %v", p, errs)
		}
	}
	for _, p := range []string{`(ab)*`, `(ab)+`, `(ab){2,}`, `(?:ab)*`} {
		if !hasCode(ValidatePattern(p, nil), ReasonGroupUnboundedQuantifier) {
			t.Errorf("unbounded group quantifier %q must be rejected", p)
		}
	}
}

func TestUnboundedInsideAQuantifiedGroupIsRejectedAtEveryDepth(t *testing.T) {
	for _, p := range []string{`([0-9]+)?`, `(a|b*)?`, `((a+))?`, `((a+){2}){2}`, `(a[b-c]*d){1,2}`} {
		if !hasCode(ValidatePattern(p, nil), ReasonUnboundedInsideQuantifiedGroup) {
			t.Errorf("%q nests an unbounded quantifier in a quantified group and must be rejected: %v",
				p, codesOf(ValidatePattern(p, nil)))
		}
	}
	for _, p := range []string{`([0-9]+)`, `(a|b*)`, `(?P<amt>[0-9][0-9,]{0,24}\.[0-9]{2})`} {
		if errs := ValidatePattern(p, nil); len(errs) != 0 {
			t.Errorf("%q has no quantified group and must be accepted: %v", p, errs)
		}
	}
}

func TestMultipleUnboundedQuantifiersInOneBranchAreRejected(t *testing.T) {
	for _, p := range []string{
		`[0-9]+[0-9]+z`,
		`[0-9]+[0-9]+[0-9]+[0-9]+z`,
		`[^\n]+X[^\n]+Y`,
		`[^\n]+X[^\n]+Y[^\n]+Z`,
		`(?P<v>[0-9]+)[0-9]+z`,
		`[0-9]+[a-z]*[0-9]+z`,
		`(a+)(b+)`,
		`(a+|b)c+`,
		`[0-9]{2,}[0-9]{3,}z`,
		`[0-9]+[0-9a-z]+z`,
		`(?:a+)(?:b+)`,
		`[0-9a-z]*[0-9]*[0-9a-z]*[0-9]*`,
	} {
		if !hasCode(ValidatePattern(p, nil), ReasonMultipleUnboundedQuantifiers) {
			t.Errorf("%q has more than one unbounded quantifier in a branch and must be rejected: %v",
				p, codesOf(ValidatePattern(p, nil)))
		}
	}

	for _, p := range []string{
		`[0-9]{2,}z`,
		`[0-9]+z|[a-z]+q`,
		`(a+|b+)c`,
		`(?:[0-9]+|[a-z]+)X`,
		`المبلغ\n(?P<ccy>[A-Z]{3} )?(?P<amt>[0-9][0-9,]{0,24}\.[0-9]{2})`,
		`الدفع الى\n(?P<v>[^\n]+)`,
		`المعاملة\n[^\n]*DEBIT(?:\n|$)`,
		`[0-9]{1,4}[0-9]{1,4}z`,
	} {
		if errs := ValidatePattern(p, nil); len(errs) != 0 {
			t.Errorf("%q has at most one unbounded quantifier per branch and must be accepted: %v", p, errs)
		}
	}
}

func TestVariableRepetitionInsideARepeatedGroupIsRejected(t *testing.T) {
	for _, p := range []string{
		`(?:[a-z0-9 ]{1,8}){8}z`,
		`(?:(?:[a-z]{1,4}){4}){4}z`,
		`(?:[a-z0-9 ]{1,4}){8}z`,
		`(?:a?){60}`,
		`(?:a|aa){30}`,
		`(?:a|){40}`,
		`(?:[)]{1,4}x){4}`,
		`(?:[\]a]{1,4}){4}`,
		`(?:a{1,4}?){4}`,
		`(?P<v>[0-9]{1,4}){2}`,
		`(?:(?:a|bcd)x){2}`,
		`(?:[0-9]{1,4}){2,4}`,
		`(?:[0-9]{1,4}){0,2}`,
		`(?:(?:[0-9]{1,4})?x?y){2}`,
		`(?:[0-9]{1,4}\-[0-9]{2}){3}`,
	} {
		if !hasCode(ValidatePattern(p, nil), ReasonNestedVariableRepetition) {
			t.Errorf("%q repeats a variable-length group and must be rejected: %v",
				p, codesOf(ValidatePattern(p, nil)))
		}
	}

	for _, p := range []string{
		`(?:[a-z]{8}){8}`,
		`[a-z]{1,64}`,
		`([0-9]{1,4})?`,
		`([0-9]{1,4}){0,1}`,
		`([0-9]{1,4}){1}`,
		`(?:ab|cd){8}`,
		`[0-9]{4,16}`,
		`(ab){2,3}`,
		`((a{4}){4}){4}`,
		`\(a{1,4}\){4}`,
		`(?:[a{1,4}]x){4}`,
		`المبلغ\n(?P<ccy>[A-Z]{3} )?(?P<amt>[0-9][0-9,]{0,24}\.[0-9]{2})`,
		`(?P<amt>(?:[A-Z]{3} )?[0-9][0-9,]{0,24}\.[0-9]{2})[ \n]has been[ \n](?:withdrawn|debited|deducted)[ \n]from your account`,
	} {
		if errs := ValidatePattern(p, nil); len(errs) != 0 {
			t.Errorf("%q does not repeat a variable-length group and must be accepted: %v", p, codesOf(errs))
		}
	}
}

func TestTheRewritesForTheBoundedCostRulesMeanTheSameThing(t *testing.T) {
	for _, pair := range []struct{ banned, rewrite string }{
		{`(?:[0-9]{1,4}){4}`, `[0-9]{4,16}`},
		{`[0-9]{1,16}[0-9]{1,16}[0-9]{1,16}z`, `[0-9]{3,48}z`},
	} {
		a := regexp.MustCompile(pair.banned)
		b := regexp.MustCompile(pair.rewrite)
		for _, s := range []string{
			"", "z", "1", "12", "123", "1234", "12345", "1z", "12z", "123z", "1234z",
			strings.Repeat("9", 15), strings.Repeat("9", 16), strings.Repeat("9", 17),
			strings.Repeat("9", 47) + "z", strings.Repeat("9", 48) + "z", strings.Repeat("9", 49) + "z",
			"a1234b", "١٢٣٤",
		} {
			if got, want := b.FindString(s), a.FindString(s); got != want {
				t.Errorf("%q vs %q on %q: rewrite matched %q, banned matched %q",
					pair.rewrite, pair.banned, s, got, want)
			}
		}
	}
}

func TestTheBacktrackingWidthOfOneBranchIsBounded(t *testing.T) {
	for _, p := range []string{
		`[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}[a-z]{1,8}z`,
		`[0-9]{1,64}[0-9]{1,64}z`,
		`[0-9]{1,25}[0-9]{1,41}z`,
		`x{0,24}x{0,24}x{0,24}`,
		`(?:a|bcd){20}`,
		`a?a?a?a?a?a?a?a?a?a?a?bz`,
	} {
		if !hasCode(ValidatePattern(p, nil), ReasonRepetitionWidthTooLarge) {
			t.Errorf("%q can split one branch more than %d ways and must be rejected: %v",
				p, MaxRepetitionWidth, codesOf(ValidatePattern(p, nil)))
		}
	}
	for _, p := range []string{
		`[0-9]{1,4}[0-9]{1,4}z`,
		`x{0,24}x{0,24}`,
		`[0-9]{1,25}[0-9]{1,40}z`,
		`[0-9]{1,32}[0-9]{1,32}z`,
		`[0-9]{3,48}z`,
		`a?a?a?a?a?a?a?a?a?a?bz`,
		`المبلغ\n(?P<ccy>[A-Z]{3} )?(?P<amt>[0-9][0-9,]{0,24}\.[0-9]{2})`,
		`الدفع الى\n(?P<v>[^\n]+)`,
		`(?P<ccy>[A-Z]{3} )?(?P<amt>[0-9][0-9,]{0,24}\.[0-9]{2})[ \n]has been[ \n](?:credited|deposited)[ \n](?:in)?to your account`,
	} {
		if errs := ValidatePattern(p, nil); len(errs) != 0 {
			t.Errorf("%q is within the width bound and must be accepted: %v", p, codesOf(errs))
		}
	}

	if w := patternWidth(t, `[0-9]{1,32}[0-9]{1,32}z`); w != MaxRepetitionWidth {
		t.Errorf("[0-9]{1,32}[0-9]{1,32}z should measure exactly %d wide, got %d", MaxRepetitionWidth, w)
	}
	if w := patternWidth(t, `[0-9]{1,25}[0-9]{1,41}z`); w != MaxRepetitionWidth+1 {
		t.Errorf("[0-9]{1,25}[0-9]{1,41}z should measure exactly %d wide, got %d", MaxRepetitionWidth+1, w)
	}

	if !hasCode(ValidatePattern(`x{0,24}x{0,24}|y{0,24}y{0,24}`, nil), ReasonRepetitionWidthTooLarge) {
		t.Error("two branches of width 625 must SUM to 1,250 and be refused; a scanner that took the " +
			"MAX across branches would report 625 and accept it")
	}
	if errs := ValidatePattern(`x{0,24}x{0,19}|y{0,24}y{0,19}`, nil); len(errs) != 0 {
		t.Errorf("two branches of width 500 sum to 1,000 and must be accepted: %v", codesOf(errs))
	}
}

func TestAnUnboundedInteriorAlsoMakesItsGroupVariable(t *testing.T) {
	for _, tc := range []struct {
		pat  string
		want []string
	}{
		{`(?:a+){2}`, []string{ReasonUnboundedInsideQuantifiedGroup, ReasonNestedVariableRepetition}},
		{`(?:[^\n]+x){2}`, []string{ReasonUnboundedInsideQuantifiedGroup, ReasonNestedVariableRepetition}},
		{`(?:a{2,}){4}`, []string{ReasonUnboundedInsideQuantifiedGroup, ReasonNestedVariableRepetition}},
		{`(?:a+)?`, []string{ReasonUnboundedInsideQuantifiedGroup}},
	} {
		got := codesOf(ValidatePattern(tc.pat, nil))
		if strings.Join(got, ",") != strings.Join(tc.want, ",") {
			t.Errorf("%q: got %v, want %v", tc.pat, got, tc.want)
		}
	}
}

func patternWidth(t *testing.T, p string) int {
	t.Helper()
	v := &patternScanner{src: []rune(p)}
	v.scan()
	return v.stack[0].width
}

func TestTheShippingSeedsHaveHeadroomUnderTheWidthBound(t *testing.T) {
	pats := seedPatterns(t)
	if len(pats) < 15 {
		t.Fatalf("found only %d patterns in seed/*.json; the walker is not reading the seeds", len(pats))
	}
	widest, widestPat := 0, ""
	for _, p := range pats {
		if errs := ValidatePattern(p, []string{"i"}); len(errs) != 0 {
			t.Errorf("SHIPPING SEED REFUSED: %q -> %v. This needs a migration, not a rule.", p, codesOf(errs))
		}
		if w := patternWidth(t, p); w > widest {
			widest, widestPat = w, p
		}
	}
	t.Logf("%d seed patterns; widest is %d (%q); the limit is %d", len(pats), widest, widestPat, MaxRepetitionWidth)
	if widest != 200 {
		t.Errorf("the widest shipping seed measures %d wide (%q); it was 200 when the bound was set. "+
			"Either a seed changed or the width arithmetic did — both need the bound re-argued",
			widest, widestPat)
	}
	if widest*4 > MaxRepetitionWidth {
		t.Errorf("the widest seed is %d and the limit is %d: less than 4x headroom is too little "+
			"for the next parser fix", widest, MaxRepetitionWidth)
	}
}

func seedPatterns(t *testing.T) []string {
	t.Helper()
	names, err := filepath.Glob("seed/*.json")
	if err != nil || len(names) == 0 {
		t.Fatalf("seed/*.json: %v (matched %d)", err, len(names))
	}
	var out []string
	var walk func(any)
	walk = func(n any) {
		switch v := n.(type) {
		case []any:
			for _, e := range v {
				walk(e)
			}
		case map[string]any:
			for k, e := range v {
				if s, ok := e.(string); ok && k == "pattern" {
					out = append(out, s)
					continue
				}
				if arr, ok := e.([]any); ok && k == "patterns" {
					for _, p := range arr {
						if s, ok := p.(string); ok {
							out = append(out, s)
						}
					}
					continue
				}
				walk(e)
			}
		}
	}
	for _, n := range names {
		b, err := os.ReadFile(n)
		if err != nil {
			t.Fatal(err)
		}
		var doc any
		if err := json.Unmarshal(b, &doc); err != nil {
			t.Fatalf("%s: %v", n, err)
		}
		walk(doc)
	}
	return out
}

func TestBoundProductIsMeasuredAlongTheNestingPath(t *testing.T) {
	for _, p := range []string{`((a{4}){4}){4}`, `a{64}`, `(a{8}){8}`} {
		if errs := ValidatePattern(p, nil); len(errs) != 0 {
			t.Errorf("%q is exactly at the bound and must be accepted: %v", p, errs)
		}
	}
	for _, p := range []string{`((a{4}){4}){5}`, `a{65}`, `(a{9}){8}`} {
		if !hasCode(ValidatePattern(p, nil), ReasonBoundProductTooLarge) {
			t.Errorf("%q exceeds the bound product and must be rejected: %v", p, codesOf(ValidatePattern(p, nil)))
		}
	}
}

func TestBareDotDetectionTracksEscapeAndClassState(t *testing.T) {
	for _, p := range []string{`a.b`, `[a]. `, `(?P<v>.)`} {
		if !hasCode(ValidatePattern(p, nil), ReasonBareDot) {
			t.Errorf("%q contains a bare dot and must be rejected", p)
		}
	}
	for _, p := range []string{`a\.b`, `[.]`, `[a.b]`, `[^\n]`, `\.`} {
		if errs := ValidatePattern(p, nil); len(errs) != 0 {
			t.Errorf("%q contains no bare dot and must be accepted: %v", p, errs)
		}
	}
}

func TestValidatePatternReportsTheOffendingOffset(t *testing.T) {
	errs := ValidatePattern(`المبلغ\s`, nil)
	if len(errs) != 1 {
		t.Fatalf("want one error, got %v", errs)
	}
	pe, okType := errs[0].(*PatternError)
	if !okType {
		t.Fatalf("want *PatternError, got %T", errs[0])
	}
	if pe.Offset != 6 {
		t.Errorf("offset = %d, want 6 (rune index of the backslash)", pe.Offset)
	}
	if !strings.Contains(pe.Error(), ReasonEscapePerlSpace) {
		t.Errorf("Error() must name the reason code, got %q", pe.Error())
	}
}

func TestToJSRewritesNamedGroups(t *testing.T) {
	if got := ToJS(`(?P<amt>[0-9]+)`); got != `(?<amt>[0-9]+)` {
		t.Fatalf("got %q", got)
	}
}

func TestToJSDoesNotRewriteAnEscapedParenFollowedByPAngle(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{`(?P<amt>[0-9]+)`, `(?<amt>[0-9]+)`},
		{`a\(?P<v`, `a\(?P<v`},
		{`[(?P<x]`, `[(?P<x]`},
		{`(?P<a>x)(?P<b>y)`, `(?<a>x)(?<b>y)`},
		{`(?:a)`, `(?:a)`},
		{`\\(?P<v>x)`, `\\(?<v>x)`},
	} {
		if got := ToJS(tc.in); got != tc.want {
			t.Errorf("ToJS(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestEveryAcceptedPatternCompilesInGo(t *testing.T) {
	for _, r := range dialectRules() {
		if _, err := regexp.Compile(r.accept); err != nil {
			t.Errorf("accepted pattern %q does not compile in Go: %v", r.accept, err)
		}
	}
}

func TestEveryReasonCodeIsDocumentedInTheSpec(t *testing.T) {
	const spec = "v2-template-format.md"
	b, err := os.ReadFile(spec)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range AllReasonCodes() {
		if !strings.Contains(string(b), c) {
			t.Errorf("reason code %q has no row in %s", c, spec)
		}
	}
}

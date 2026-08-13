use onig::{Regex, Region, SearchOptions};

struct Case {
    pattern: &'static str,
    text: &'static str,
    start: usize,
    want: Option<(usize, usize)>,
}

const CASES: &[Case] = &[
    Case { pattern: r"a{2,3}+a", text: "aaa", start: 0, want: Some((0, 3)) },
    Case { pattern: r"a{2,3}+a", text: "aaaa", start: 0, want: Some((0, 4)) },
    Case { pattern: r"a{2,3}+b", text: "aaab", start: 0, want: Some((0, 4)) },
    Case { pattern: r"a{2,3}+b", text: "aab", start: 0, want: Some((0, 3)) },
    Case { pattern: r"a{,2}+a", text: "aa", start: 0, want: Some((0, 2)) },
    Case { pattern: r"a{,2}+a", text: "aaa", start: 0, want: Some((0, 3)) },
    Case { pattern: r"foo\Kbar", text: "foobar", start: 0, want: Some((3, 6)) },
    Case { pattern: r"a\Kb", text: "ab", start: 0, want: Some((1, 2)) },
    Case { pattern: r"(foo)\Kbar", text: "foobar", start: 0, want: Some((3, 6)) },
    Case { pattern: r"(?:foo|fo)\Ko", text: "foo", start: 0, want: Some((2, 3)) },
    Case { pattern: r"foo\K(?=bar)bar", text: "foobar", start: 0, want: Some((3, 6)) },
];

const COMPILE_ERRORS: &[&str] = &[
    r"(?=a)*",
    r"(?=a)+",
    r"(?=a)?",
    r"(?=a){2}",
    r"(?!a)*",
    r"(?!a)+",
    r"(?!a)?",
    r"(?!a){2}",
    r"(?<=a)*",
    r"(?<=a)+",
    r"(?<=a)?",
    r"(?<=a){2}",
    r"(?<!a)*",
    r"(?<!a)+",
    r"(?<!a)?",
    r"(?<!a){2}",
    r"a(?i)*",
    r"a(?-i){1,2}",
    r"(?<type-name>a)\k<type-name>",
    r"(?'type-name'a)\k'type-name'",
    r"(?<type-name>a)?(?(<type-name>)yes|no)",
    r"(?<type.name>a)\k<type.name>",
    r"(?<type.name>a)?(?(<type.name>)yes|no)",
];

fn main() {
    for case in CASES {
        let regex = Regex::new(case.pattern).unwrap_or_else(|err| {
            panic!("failed to compile {:?}: {}", case.pattern, err);
        });
        let mut region = Region::new();
        let start = regex.search_with_options(
            case.text,
            case.start,
            case.text.len(),
            SearchOptions::SEARCH_OPTION_NONE,
            Some(&mut region),
        );
        let got = start.and_then(|_| region.pos(0));
        assert_eq!(got, case.want, "{}", case.pattern);
    }
    for pattern in COMPILE_ERRORS {
        assert!(Regex::new(pattern).is_err(), "expected compile error: {}", pattern);
    }
    println!("native onig skipped cases ok: {} matched, {} rejected", CASES.len(), COMPILE_ERRORS.len());
}

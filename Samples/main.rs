use std::collections::HashMap;

/// 统计词频
fn main() {
    let mut m: HashMap<&str, usize> = HashMap::new();
    for w in "a b a".split_whitespace() { *m.entry(w).or_default() += 1; }
    println!("{m:?}");
}

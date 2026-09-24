use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;

use quote::ToTokens;
use syn::{Attribute, Fields, ImplItem, Item, TraitItem};

#[derive(Clone, Debug, PartialEq, Eq)]
struct ItemBoundary {
    identity: String,
    docs: Vec<String>,
    attributes: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct MetadataChange {
    identity: String,
    before: ItemBoundary,
    after: ItemBoundary,
}

#[test]
fn keeps_metadata_with_its_existing_item_when_an_item_is_inserted() {
    let before = r#"
/// Describes the existing item.
#[allow(dead_code)]
fn existing() {}
"#;
    let after = r#"
fn inserted() {}

/// Describes the existing item.
#[allow(dead_code)]
fn existing() {}
"#;

    assert!(changed_metadata(before, after).is_empty());
}

#[test]
fn reports_metadata_reparented_by_an_insertion() {
    let before = r#"
/// Describes the existing item.
#[allow(dead_code)]
fn existing() {}
"#;
    let after = r#"
/// Describes the existing item.
#[allow(dead_code)]
fn inserted() {}
fn existing() {}
"#;

    let changed = changed_metadata(before, after);
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0].identity, "fn existing");
    assert_eq!(changed[0].before.docs.len(), 1);
    assert!(changed[0].after.docs.is_empty());
    assert_eq!(changed[0].before.attributes, vec!["allow (dead_code)"]);
    assert!(changed[0].after.attributes.is_empty());
}

#[test]
fn reports_metadata_reparented_by_a_deletion() {
    let before = r#"
fn before() {}

/// Describes the retained item.
#[allow(dead_code)]
fn retained() {}
"#;
    let after = r#"
/// Describes the retained item.
#[allow(dead_code)]
fn before() {}
"#;

    let changed = changed_metadata(before, after);
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0].identity, "fn before");
    assert!(changed[0].before.docs.is_empty());
    assert_eq!(changed[0].after.docs.len(), 1);
}

#[test]
fn distinguishes_same_named_methods_in_separate_implementations() {
    let before = r#"
struct A;
struct B;
impl A {
    /// A constructor.
    fn new() -> Self { Self }
}
impl B {
    fn new() -> Self { Self }
}
"#;
    let after = r#"
struct A;
struct B;
impl A {
    fn new() -> Self { Self }
}
impl B {
    fn new() -> Self { Self }
}
"#;

    let changed = changed_metadata(before, after);
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0].identity, "impl A::fn new");
}

#[test]
fn reports_metadata_changed_on_the_first_of_repeated_inherent_implementations() {
    let before = r#"
struct Example;

/// First implementation.
impl Example {
    fn first() {}
}

impl Example {
    fn second() {}
}
"#;
    let after = r#"
struct Example;

impl Example {
    fn first() {}
}

impl Example {
    fn second() {}
}
"#;

    let changed = changed_metadata(before, after);
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0].identity, "impl Example");
}

#[test]
fn recognizes_generic_implementations_fields_and_variants() {
    let source = r#"
/// Generic implementation.
impl<T> Example<T> {
    /// A field-like method.
    fn value(&self) {}
}

struct Record {
    /// A documented field.
    field: String,
}

enum Choice {
    /// A documented variant.
    First,
}
"#;

    let found = item_map(source);
    assert!(found.contains_key("impl Example < T >"));
    assert!(found.contains_key("impl Example < T >::fn value"));
    assert!(found.contains_key("struct Record::field field"));
    assert!(found.contains_key("enum Choice::variant First"));
}

#[test]
fn reports_metadata_changes_for_generic_implementations_fields_variants_unions_and_uses() {
    let cases = [
        (
            "impl Example < T >",
            r#"
/// Generic implementation.
impl<T> Example<T> {}
"#,
            r#"
impl<T> Example<T> {}
"#,
        ),
        (
            "struct Record::field field",
            r#"
struct Record {
    /// A documented field.
    field: String,
}
"#,
            r#"
struct Record {
    field: String,
}
"#,
        ),
        (
            "enum Choice::variant First",
            r#"
enum Choice {
    /// A documented variant.
    First,
}
"#,
            r#"
enum Choice {
    First,
}
"#,
        ),
        (
            "union Bits::field value",
            r#"
union Bits {
    /// A documented field.
    value: u64,
}
"#,
            r#"
union Bits {
    value: u64,
}
"#,
        ),
        (
            "use std :: collections :: BTreeMap",
            r#"
/// A documented import.
use std::collections::BTreeMap;
"#,
            r#"
use std::collections::BTreeMap;
"#,
        ),
    ];

    for (identity, before, after) in cases {
        let changed = changed_metadata(before, after);
        assert_eq!(changed.len(), 1, "{identity}");
        assert_eq!(changed[0].identity, identity);
    }
}

#[test]
fn current_rust_diff_keeps_metadata_with_its_existing_items() {
    let root = repo_root();
    let base = git(&root, &["merge-base", "origin/main", "HEAD"]);
    let paths = git(
        &root,
        &[
            "diff",
            "--name-only",
            &format!("{base}...HEAD"),
            "--",
            "fleet-view/src",
        ],
    );

    let mut failures = BTreeMap::new();
    for path in paths.lines().filter(|path| path.ends_with(".rs")) {
        let Some(before) = git_optional(&root, &["show", &format!("{base}:{path}")]) else {
            continue;
        };
        let after_path = root.join(path);
        let Ok(after) = std::fs::read_to_string(&after_path) else {
            continue;
        };
        let changed = changed_metadata(&before, &after);
        if !changed.is_empty() {
            failures.insert(path, changed);
        }
    }

    assert!(
        failures.is_empty(),
        "Rust item metadata moved away from an existing declaration: {failures:#?}"
    );
}

fn changed_metadata(before: &str, after: &str) -> Vec<MetadataChange> {
    let before = item_map(before);
    let after = item_map(after);
    before
        .into_iter()
        .flat_map(|(identity, before_items)| {
            let Some(after_items) = after.get(&identity) else {
                return Vec::new();
            };
            before_items
                .into_iter()
                .zip(after_items)
                .filter_map(|(before, after)| {
                    (before.docs != after.docs || before.attributes != after.attributes).then(
                        || MetadataChange {
                            identity: identity.clone(),
                            before,
                            after: after.clone(),
                        },
                    )
                })
                .collect()
        })
        .collect()
}

fn item_map(source: &str) -> BTreeMap<String, Vec<ItemBoundary>> {
    let file = syn::parse_file(source).expect("the Rust fixture must parse");
    let mut collector = Collector::default();
    collector.collect_items(&file.items);
    collector
        .items
        .into_iter()
        .fold(BTreeMap::new(), |mut items, item| {
            items.entry(item.identity.clone()).or_default().push(item);
            items
        })
}

#[derive(Default)]
struct Collector {
    scope: Vec<String>,
    items: Vec<ItemBoundary>,
}

impl Collector {
    fn collect_items(&mut self, items: &[Item]) {
        for item in items {
            match item {
                Item::Const(item) => self.record("const", &item.ident.to_string(), &item.attrs),
                Item::Enum(item) => {
                    self.record("enum", &item.ident.to_string(), &item.attrs);
                    self.with_scope(format!("enum {}", item.ident), |collector| {
                        for variant in &item.variants {
                            collector.record("variant", &variant.ident.to_string(), &variant.attrs);
                            collector.with_scope(
                                format!("variant {}", variant.ident),
                                |collector| {
                                    collector.collect_fields(&variant.fields);
                                },
                            );
                        }
                    });
                }
                Item::ExternCrate(item) => {
                    self.record("extern crate", &item.ident.to_string(), &item.attrs)
                }
                Item::Fn(item) => self.record("fn", &item.sig.ident.to_string(), &item.attrs),
                Item::ForeignMod(item) => self.record(
                    "extern",
                    &item.abi.to_token_stream().to_string(),
                    &item.attrs,
                ),
                Item::Impl(item) => {
                    let identity = implementation_identity(item);
                    self.record("impl", &identity, &item.attrs);
                    self.with_scope(format!("impl {identity}"), |collector| {
                        for item in &item.items {
                            match item {
                                ImplItem::Const(item) => {
                                    collector.record("const", &item.ident.to_string(), &item.attrs)
                                }
                                ImplItem::Fn(item) => {
                                    collector.record("fn", &item.sig.ident.to_string(), &item.attrs)
                                }
                                ImplItem::Type(item) => {
                                    collector.record("type", &item.ident.to_string(), &item.attrs)
                                }
                                ImplItem::Macro(item) => collector.record(
                                    "macro",
                                    &item.mac.path.to_token_stream().to_string(),
                                    &item.attrs,
                                ),
                                _ => {}
                            }
                        }
                    });
                }
                Item::Macro(item) => self.record(
                    "macro",
                    &item.mac.path.to_token_stream().to_string(),
                    &item.attrs,
                ),
                Item::Mod(item) => {
                    self.record("mod", &item.ident.to_string(), &item.attrs);
                    if let Some((_, items)) = &item.content {
                        self.with_scope(format!("mod {}", item.ident), |collector| {
                            collector.collect_items(items)
                        });
                    }
                }
                Item::Static(item) => self.record("static", &item.ident.to_string(), &item.attrs),
                Item::Struct(item) => {
                    self.record("struct", &item.ident.to_string(), &item.attrs);
                    self.with_scope(format!("struct {}", item.ident), |collector| {
                        collector.collect_fields(&item.fields)
                    });
                }
                Item::Trait(item) => {
                    self.record("trait", &item.ident.to_string(), &item.attrs);
                    self.with_scope(format!("trait {}", item.ident), |collector| {
                        for item in &item.items {
                            match item {
                                TraitItem::Const(item) => {
                                    collector.record("const", &item.ident.to_string(), &item.attrs)
                                }
                                TraitItem::Fn(item) => {
                                    collector.record("fn", &item.sig.ident.to_string(), &item.attrs)
                                }
                                TraitItem::Type(item) => {
                                    collector.record("type", &item.ident.to_string(), &item.attrs)
                                }
                                TraitItem::Macro(item) => collector.record(
                                    "macro",
                                    &item.mac.path.to_token_stream().to_string(),
                                    &item.attrs,
                                ),
                                _ => {}
                            }
                        }
                    });
                }
                Item::TraitAlias(item) => {
                    self.record("trait alias", &item.ident.to_string(), &item.attrs)
                }
                Item::Type(item) => self.record("type", &item.ident.to_string(), &item.attrs),
                Item::Union(item) => {
                    self.record("union", &item.ident.to_string(), &item.attrs);
                    self.with_scope(format!("union {}", item.ident), |collector| {
                        for field in &item.fields.named {
                            collector.record(
                                "field",
                                &field.ident.as_ref().expect("union field").to_string(),
                                &field.attrs,
                            );
                        }
                    });
                }
                Item::Use(item) => {
                    self.record("use", &item.tree.to_token_stream().to_string(), &item.attrs)
                }
                _ => {}
            }
        }
    }

    fn collect_fields(&mut self, fields: &Fields) {
        match fields {
            Fields::Named(fields) => {
                for field in &fields.named {
                    self.record(
                        "field",
                        &field.ident.as_ref().expect("named field").to_string(),
                        &field.attrs,
                    );
                }
            }
            Fields::Unnamed(fields) => {
                for (index, field) in fields.unnamed.iter().enumerate() {
                    self.record("field", &index.to_string(), &field.attrs);
                }
            }
            Fields::Unit => {}
        }
    }

    fn record(&mut self, kind: &str, name: &str, attributes: &[Attribute]) {
        let prefix = (!self.scope.is_empty()).then(|| format!("{}::", self.scope.join("::")));
        self.items.push(ItemBoundary {
            identity: format!("{}{kind} {name}", prefix.unwrap_or_default()),
            docs: attributes
                .iter()
                .filter(|attribute| attribute.path().is_ident("doc"))
                .map(attribute_text)
                .collect(),
            attributes: attributes
                .iter()
                .filter(|attribute| !attribute.path().is_ident("doc"))
                .map(attribute_text)
                .collect(),
        });
    }

    fn with_scope(&mut self, scope: String, collect: impl FnOnce(&mut Self)) {
        self.scope.push(scope);
        collect(self);
        self.scope.pop();
    }
}

fn implementation_identity(item: &syn::ItemImpl) -> String {
    let self_type = item.self_ty.to_token_stream().to_string();
    item.trait_
        .as_ref()
        .map(|(_, path, _)| format!("{} for {self_type}", path.to_token_stream()))
        .unwrap_or(self_type)
}

fn attribute_text(attribute: &Attribute) -> String {
    attribute.meta.to_token_stream().to_string()
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fleet-view has a parent directory")
        .to_path_buf()
}

fn git(root: &std::path::Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(root)
        .output()
        .unwrap_or_else(|error| panic!("cannot run git {}: {error}", args.join(" ")));
    assert!(
        output.status.success(),
        "git {} failed: {}",
        args.join(" "),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .unwrap_or_else(|error| panic!("git {} returned non-UTF-8 output: {error}", args.join(" ")))
        .trim()
        .to_owned()
}

fn git_optional(root: &std::path::Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(root)
        .output()
        .unwrap_or_else(|error| panic!("cannot run git {}: {error}", args.join(" ")));
    output.status.success().then(|| {
        String::from_utf8(output.stdout)
            .unwrap_or_else(|error| {
                panic!("git {} returned non-UTF-8 output: {error}", args.join(" "))
            })
            .trim()
            .to_owned()
    })
}

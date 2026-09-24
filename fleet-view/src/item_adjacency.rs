use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    pub identity: String,
    pub docs: Vec<String>,
    pub attributes: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MetadataChange {
    pub identity: String,
    pub before: Item,
    pub after: Item,
}

pub fn items(source: &str) -> Vec<Item> {
    let lines: Vec<&str> = source.lines().collect();
    let mut found = Vec::new();
    let mut docs = Vec::new();
    let mut attributes = Vec::new();
    let mut index = 0;

    while let Some(line) = lines.get(index) {
        let trimmed = line.trim();
        if trimmed.starts_with("///") {
            docs.push(trimmed.to_owned());
            index += 1;
            continue;
        }
        if trimmed.starts_with("#") && trimmed.get(1..2) == Some("[") {
            let (attribute, next) = attribute_at(&lines, index);
            attributes.push(attribute);
            index = next;
            continue;
        }
        if trimmed.is_empty() {
            docs.clear();
            attributes.clear();
            index += 1;
            continue;
        }
        if let Some(identity) = declaration_identity(trimmed) {
            found.push(Item {
                identity,
                docs: std::mem::take(&mut docs),
                attributes: std::mem::take(&mut attributes),
            });
        } else {
            docs.clear();
            attributes.clear();
        }
        index += 1;
    }

    found
}

pub fn changed_metadata(before: &str, after: &str) -> Vec<MetadataChange> {
    let before = item_map(before);
    let after = item_map(after);
    before
        .into_iter()
        .filter_map(|(identity, before)| {
            let after = after.get(&identity)?;
            (before.docs != after.docs || before.attributes != after.attributes).then(|| {
                MetadataChange {
                    identity,
                    before,
                    after: after.clone(),
                }
            })
        })
        .collect()
}

fn item_map(source: &str) -> BTreeMap<String, Item> {
    items(source)
        .into_iter()
        .map(|item| (item.identity.clone(), item))
        .collect()
}

fn attribute_at(lines: &[&str], start: usize) -> (String, usize) {
    let mut depth = 0;
    let mut attribute = Vec::new();
    let mut index = start;
    while let Some(line) = lines.get(index) {
        let trimmed = line.trim();
        depth += trimmed.matches('[').count();
        depth -= trimmed.matches(']').count();
        attribute.push(trimmed);
        index += 1;
        if depth == 0 {
            break;
        }
    }
    (attribute.join("\n"), index)
}

fn declaration_identity(line: &str) -> Option<String> {
    let words: Vec<&str> = line.split_whitespace().collect();
    if let Some(fn_index) = words.iter().position(|word| *word == "fn") {
        let name = words.get(fn_index + 1)?.split(['(', '<']).next()?;
        return Some(format!("fn {name}"));
    }
    declaration_without_fn(&words)
}

fn declaration_without_fn(words: &[&str]) -> Option<String> {
    for keyword in ["struct", "enum", "trait", "mod", "type", "const", "static"] {
        if let Some(index) = words.iter().position(|word| *word == keyword) {
            let name = words.get(index + 1)?.trim_end_matches([';', '{']);
            return Some(format!("{keyword} {name}"));
        }
    }
    if let Some(index) = words.iter().position(|word| *word == "impl") {
        let declaration = words[index + 1..]
            .join(" ")
            .trim_end_matches('{')
            .trim()
            .to_owned();
        return Some(format!("impl {declaration}"));
    }
    None
}

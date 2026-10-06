//! quick-xml skips whitespace-only text when visiting an attribute-bearing map.
//! Preserve that text in String/Value before converting its serde model to a DB.
//! Scalar deserialization uses the same XML library and retains text verbatim.

use super::{
    entry::Entry,
    group::{Group, GroupOrEntry},
};
use quick_xml::{events::Event, DeError, Reader};

pub(super) fn restore(data: &[u8], root: &mut Group) -> Result<(), DeError> {
    let mut reader = Reader::from_reader(data);
    let mut tags = Vec::<String>::new();
    let mut entries = Vec::<Vec<Option<String>>>::new();
    let mut active_entries = Vec::<usize>::new();
    loop {
        let start = reader.buffer_position() as usize;
        match reader.read_event()? {
            Event::Start(tag) => {
                let name = tag.name();
                if name.as_ref() == "Entry" {
                    active_entries.push(entries.len());
                    entries.push(Vec::new());
                }
                if name.as_ref() == "String" && tags.last().is_some_and(|n| n == "Entry") {
                    if let Some(&entry) = active_entries.last() {
                        entries[entry].push(None);
                    }
                }
                if name.as_ref() == "Value"
                    && tags.last().is_some_and(|n| n == "String")
                    && tags.iter().rev().nth(1).is_some_and(|n| n == "Entry")
                {
                    reader.read_to_end(name)?;
                    let end = reader.buffer_position() as usize;
                    let text: String = quick_xml::de::from_reader(&data[start..end])?;
                    if !text.is_empty() && text.chars().all(char::is_whitespace) {
                        let field = active_entries
                            .last()
                            .and_then(|&entry| entries[entry].last_mut())
                            .ok_or_else(|| {
                                DeError::Custom("Value outside an entry string".into())
                            })?;
                        *field = Some(text);
                    }
                    continue;
                }
                tags.push(name.as_ref().to_string());
            }
            Event::End(tag) => {
                if tag.name().as_ref() == "Entry" {
                    active_entries.pop();
                }
                tags.pop();
            }
            Event::Eof => break,
            _ => {}
        }
    }
    let mut entries = entries.into_iter();
    restore_group(root, &mut entries)?;
    if entries.next().is_some() {
        return Err(DeError::Custom(
            "XML entry layout differs from its model".into(),
        ));
    }
    Ok(())
}

fn restore_group(
    group: &mut Group,
    entries: &mut impl Iterator<Item = Vec<Option<String>>>,
) -> Result<(), DeError> {
    for child in &mut group.children {
        match child {
            GroupOrEntry::Group(group) => restore_group(group, entries)?,
            GroupOrEntry::Entry(entry) => restore_entry(entry, entries)?,
        }
    }
    Ok(())
}

fn restore_entry(
    entry: &mut Entry,
    entries: &mut impl Iterator<Item = Vec<Option<String>>>,
) -> Result<(), DeError> {
    let fields = entries
        .next()
        .ok_or_else(|| DeError::Custom("Missing original XML entry".into()))?;
    if fields.len() != entry.string_fields.len() {
        return Err(DeError::Custom(
            "XML string layout differs from its model".into(),
        ));
    }
    for (original, field) in fields.into_iter().zip(&mut entry.string_fields) {
        if let Some(text) = original {
            field.value.value = Some(text);
        }
    }
    if let Some(history) = &mut entry.history {
        for old in &mut history.entries {
            restore_entry(old, entries)?;
        }
    }
    Ok(())
}

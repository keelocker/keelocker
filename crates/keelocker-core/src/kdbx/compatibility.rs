use crate::CoreError;

// keepass-rs does not retain arbitrary XML extensions. Refuse these documents
// instead of silently dropping fields on a later save. This is schema validation,
// not a KDBX parser: decryption and XML extraction belong to keepass-rs.
pub fn check_xml(xml: &[u8]) -> Result<(), CoreError> {
    let text = std::str::from_utf8(xml).map_err(|_| CoreError::CorruptedDatabase)?;
    let doc = roxmltree::Document::parse(text).map_err(|_| CoreError::CorruptedDatabase)?;
    let mut uuids = std::collections::HashSet::new();
    for node in doc.descendants().filter(|n| n.is_element()) {
        let parent = node
            .parent_element()
            .map(|p| p.tag_name().name())
            .unwrap_or("");
        let allowed = match parent {
            "" => "KeePassFile",
            "KeePassFile" => "Meta Root",
            "Root" => "Group DeletedObjects",
            "Meta" => "Generator HeaderHash DatabaseName DatabaseNameChanged DatabaseDescription DatabaseDescriptionChanged DefaultUserName DefaultUserNameChanged MaintenanceHistoryDays Color MasterKeyChanged MasterKeyChangeRec MasterKeyChangeForce MemoryProtection CustomIcons RecycleBinEnabled RecycleBinUUID RecycleBinChanged EntryTemplatesGroup EntryTemplatesGroupChanged LastSelectedGroup LastTopVisibleGroup HistoryMaxItems HistoryMaxSize SettingsChanged Binaries CustomData",
            "Group" => "UUID Name Notes IconID CustomIconUUID Times IsExpanded DefaultAutoTypeSequence EnableAutoType EnableSearching LastTopVisibleEntry PreviousParentGroup Tags CustomData Group Entry",
            "Entry" => "UUID IconID CustomIconUUID ForegroundColor BackgroundColor OverrideURL QualityCheck Tags PreviousParentGroup Times String Binary AutoType History CustomData",
            "Times" => "LastModificationTime CreationTime LastAccessTime ExpiryTime Expires UsageCount LocationChanged",
            "String" | "Binary" => "Key Value",
            "CustomData" => "Item",
            "Item" => "Key Value LastModificationTime",
            "History" => "Entry",
            "MemoryProtection" => "ProtectTitle ProtectUserName ProtectPassword ProtectURL ProtectNotes",
            "CustomIcons" => "Icon",
            "Icon" => "UUID Data Name LastModificationTime",
            "Binaries" => "Binary",
            "AutoType" => "Enabled DataTransferObfuscation DefaultSequence Association",
            "Association" => "Window KeystrokeSequence",
            "DeletedObjects" => "DeletedObject",
            "DeletedObject" => "UUID DeletionTime",
            _ => "",
        };
        if node.tag_name().namespace().is_some()
            || !allowed
                .split_whitespace()
                .any(|s| s == node.tag_name().name())
        {
            return Err(CoreError::UnsupportedDatabase);
        }
        for attribute in node.attributes() {
            let valid = match node.tag_name().name() {
                "Value" => ["Protected", "ProtectInMemory", "Ref"].contains(&attribute.name()),
                "Binary" => {
                    ["ID", "Compressed", "Protected", "ProtectInMemory"].contains(&attribute.name())
                }
                _ => false,
            };
            if !valid || attribute.namespace().is_some() {
                return Err(CoreError::UnsupportedDatabase);
            }
        }
        // Maps in the upstream model cannot preserve duplicate custom keys.
        if ["Entry", "CustomData"].contains(&node.tag_name().name()) {
            let mut keys = std::collections::HashSet::new();
            for field in node.children().filter(|n| {
                n.is_element() && ["String", "Binary", "Item"].contains(&n.tag_name().name())
            }) {
                if let Some(key) = field.children().find(|n| n.has_tag_name("Key")) {
                    if !keys.insert((field.tag_name().name(), key.text().unwrap_or_default())) {
                        return Err(CoreError::UnsupportedDatabase);
                    }
                }
            }
        }
        if ["Entry", "Group"].contains(&node.tag_name().name())
            && !node.ancestors().any(|n| n.has_tag_name("History"))
        {
            if let Some(uuid) = node.children().find(|n| n.has_tag_name("UUID")) {
                if !uuids.insert(uuid.text().unwrap_or_default()) {
                    return Err(CoreError::CorruptedDatabase);
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn extensions_are_refused_instead_of_dropped() {
        for xml in [
            "<KeePassFile><Meta><PluginSecret>value</PluginSecret></Meta></KeePassFile>",
            "<KeePassFile><Meta><MasterKeyChangeForceOnce>True</MasterKeyChangeForceOnce></Meta></KeePassFile>",
            "<KeePassFile><Root><Group><Entry><String><Key>A</Key><Value>a</Value></String><String><Key>A</Key><Value>b</Value></String></Entry></Group></Root></KeePassFile>",
        ] { assert_eq!(check_xml(xml.as_bytes()), Err(CoreError::UnsupportedDatabase)); }
    }
    #[test]
    fn arbitrary_custom_data_keys_are_supported() {
        assert_eq!(check_xml(b"<KeePassFile><Meta><CustomData><Item><Key>plugin-key</Key><Value>plugin-value</Value></Item></CustomData></Meta></KeePassFile>"), Ok(()));
    }
    #[test]
    fn malformed_xml_and_duplicate_ids_fail() {
        assert_eq!(
            check_xml(b"<KeePassFile>"),
            Err(CoreError::CorruptedDatabase)
        );
        assert_eq!(check_xml(b"<KeePassFile><Root><Group><UUID>same</UUID><Entry><UUID>same</UUID></Entry></Group></Root></KeePassFile>"), Err(CoreError::CorruptedDatabase));
    }
}

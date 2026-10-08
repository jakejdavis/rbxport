//! The playlist tree, flattened with depths, as the command layer builds it.

use rbl_index::{Library, Playlists, NO_ID};

use crate::types::{NodeKind, TreeNode};

fn count(len: usize) -> u32 {
    u32::try_from(len).unwrap_or(u32::MAX)
}

pub(crate) fn build_tree(library: &Library) -> Vec<TreeNode> {
    let playlists = library.playlists();
    let histories = library.histories();
    let mut nodes = vec![
        TreeNode {
            id: "all".into(),
            name: "All Tracks".into(),
            kind: NodeKind::AllTracks,
            depth: 0,
            expanded: None,
            child_count: Some(count(library.len())),
        },
        TreeNode {
            id: "playlists".into(),
            name: "Playlists".into(),
            kind: NodeKind::Collection,
            depth: 0,
            expanded: Some(true),
            child_count: Some(count(playlists.len())),
        },
    ];
    push_lists(&mut nodes, &playlists, &Style::PLAYLISTS, 2);
    if !histories.is_empty() {
        nodes.push(TreeNode {
            id: "histories".into(),
            name: "Histories".into(),
            kind: NodeKind::Histories,
            depth: 0,
            expanded: Some(true),
            child_count: Some(count(histories.len())),
        });
        push_lists(&mut nodes, &histories, &Style::HISTORIES, 2);
    }
    nodes
}

struct Style {
    folder: NodeKind,
    leaf: NodeKind,
    smart: NodeKind,
    calendar: bool,
}

impl Style {
    const PLAYLISTS: Self = Self {
        folder: NodeKind::Folder,
        leaf: NodeKind::Playlist,
        smart: NodeKind::SmartPlaylist,
        calendar: false,
    };
    const HISTORIES: Self = Self {
        folder: NodeKind::HistoryFolder,
        leaf: NodeKind::History,
        smart: NodeKind::History,
        calendar: true,
    };
}

fn month_name(number: &str) -> Option<&'static str> {
    const MONTHS: [&str; 12] = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September",
        "October", "November", "December",
    ];
    let month = number.parse::<usize>().ok()?;
    MONTHS.get(month.checked_sub(1)?).copied()
}

/// Flattens one list tree onto `nodes`, depth-first. Iterative with a visited
/// set, so a corrupt parent cycle cannot recurse forever.
fn push_lists(nodes: &mut Vec<TreeNode>, lists: &Playlists, style: &Style, open_to: u32) {
    let mut children: Vec<Vec<usize>> = vec![Vec::new(); lists.len()];
    let mut roots: Vec<usize> = Vec::new();
    for index in 0..lists.len() {
        match lists.parent.get(index).copied() {
            Some(parent) if parent != NO_ID && (parent as usize) < lists.len() => {
                if let Some(bucket) = children.get_mut(parent as usize) {
                    bucket.push(index);
                }
            }
            _ => roots.push(index),
        }
    }
    if style.calendar {
        let by_date = |index: &usize| -> (u64, u32) {
            if lists.is_folder(*index) {
                (lists.name(*index).parse::<u64>().unwrap_or(u64::MAX), 0)
            } else {
                (u64::MAX, lists.seq.get(*index).copied().unwrap_or(u32::MAX))
            }
        };
        roots.sort_by_key(by_date);
        for bucket in &mut children {
            bucket.sort_by_key(by_date);
        }
    }

    let mut stack: Vec<(usize, u32)> = roots.iter().rev().map(|&i| (i, 1_u32)).collect();
    let mut visited = vec![false; lists.len()];
    while let Some((index, depth)) = stack.pop() {
        if visited.get(index).copied().unwrap_or(true) {
            continue;
        }
        if let Some(slot) = visited.get_mut(index) {
            *slot = true;
        }
        let under = children.get(index).map_or(0, Vec::len);
        let members = lists.members.get(index).map_or(0, Vec::len);
        let folder = lists.is_folder(index) || under > 0;
        let name = lists.name(index);
        let name = match (style.calendar && folder && depth == 2, month_name(name)) {
            (true, Some(month)) => month.to_owned(),
            _ => name.to_owned(),
        };
        let smart = !folder && lists.is_smart(index);
        nodes.push(TreeNode {
            id: lists.ids.get(index).copied().unwrap_or(0).to_string(),
            name,
            kind: if folder {
                style.folder
            } else if smart {
                style.smart
            } else {
                style.leaf
            },
            depth,
            expanded: if folder { Some(depth < open_to) } else { None },
            child_count: if smart { None } else { Some(count(if folder { under } else { members })) },
        });
        if let Some(below) = children.get(index) {
            for &child in below.iter().rev() {
                stack.push((child, depth + 1));
            }
        }
    }
}

// Marker parser contract is pinned by tests/lib/session-args.cases.
use chrono::{DateTime,Utc};
use serde::Deserialize;
use std::{collections::BTreeMap,path::Path};

#[derive(Clone,Debug,PartialEq)] pub enum RowState { Working,Asking,Waiting,Idle,Up,Dead,Unknown(String),Invalid }
#[derive(Clone,Debug,Deserialize)] pub struct StateRecord { pub state:String, pub phase:Option<String>, pub bead:Option<String>, pub since:Option<DateTime<Utc>>, pub phase_since:Option<DateTime<Utc>>, pub pid:u32 }
#[derive(Clone,Debug)] pub enum StateObservation { Missing, Parsed(StateRecord), Invalid(String) }
#[derive(Clone,Debug)] pub struct StateInput { pub observation:StateObservation, pub stop_requested:bool }
pub type StateInputs=BTreeMap<String,StateInput>;
#[derive(Clone,Debug,PartialEq)] pub enum AgentKind { Interactive,Implementer }
#[derive(Clone,Debug)] pub struct RosterEntry { pub name:String,pub role:String,pub kind:AgentKind }
#[derive(Clone,Debug)] pub struct ProcessRow { pub pid:u32,pub ppid:Option<u32>,pub args:String }
#[derive(Clone,Debug)] pub struct FleetRow { pub name:String,pub role:String,pub state:RowState,pub phase:Option<String>,pub bead:Option<String>,pub since:Option<DateTime<Utc>>,pub phase_since:Option<DateTime<Utc>>,pub for_text:String,pub sessions:usize,pub stop_requested:bool,pub unverified:bool,pub diagnostic:Option<String> }
#[derive(Clone,Debug,Deserialize)] pub struct Bead { pub id:String,pub title:String,#[serde(default)] pub status:String,#[serde(rename="type",default)] pub issue_type:String,#[serde(default)] pub labels:Vec<String>,pub priority:Option<u8>,pub updated_at:Option<DateTime<Utc>>,pub assignee:Option<String>,#[serde(skip)] pub paused_at:Option<DateTime<Utc>> }
#[derive(Clone,Debug,Default)] pub struct WorkBuckets { pub claimed:Vec<Bead>,pub planned:Vec<Bead>,pub being_planned:Vec<Bead>,pub unplanned:Vec<Bead>,pub paused:Vec<Bead>,pub merged:Vec<Bead> }

fn marker(args:&str,name:&str,root:&Path)->bool { let needle=format!("This session is {} of the cerebro fleet rooted at {}/.",name,root.display()); args.contains(&needle) }
pub fn session_marker_matches(args:&str,name:&str,root:&Path)->bool { marker(args,name,root) }
pub fn parse_processes(text:&str)->Result<Vec<ProcessRow>,String> {
 let mut rows=Vec::new();
 for line in text.lines() {
  let p:Vec<_>=line.splitn(3,' ').collect();
  if p.len()>=3 && p[0].parse::<u32>().is_ok() {
   rows.push(ProcessRow{pid:p[0].parse().unwrap(),ppid:p[1].parse().ok(),args:p[2].to_string()});
  } else if !line.trim().is_empty() {
   if let Some(last)=rows.last_mut(){last.args.push('\n');last.args.push_str(line)} else{return Err(format!("invalid process row: {line}"))}
  }
 }
 Ok(rows)
}
fn live(name:&str,root:&Path,ps:&[ProcessRow])->Vec<u32>{
 let ids:Vec<u32>=ps.iter().filter(|p|marker(&p.args,name,root)).map(|p|p.pid).collect();
 ids.iter().copied().filter(|id| !ps.iter().any(|p|p.ppid==Some(*id)&&ids.contains(&p.pid))).collect()
}
pub fn derive_fleet(roster:&[RosterEntry], states:&StateInputs, processes:&[ProcessRow], root:&Path, now:DateTime<Utc>)->Vec<FleetRow>{
 roster.iter().map(|r| { let input=states.get(&r.name); let unverified=false; let (state,phase,bead,since,phase_since,diag)=match input.map(|x|&x.observation) {
  Some(StateObservation::Invalid(e))=>(RowState::Invalid,None,None,None,None,Some(e.clone())),
  Some(StateObservation::Parsed(s))=>{let l=live(&r.name,root,processes); if l.is_empty(){(RowState::Dead,s.phase.clone(),s.bead.clone(),s.since,s.phase_since,None)} else {(match s.state.as_str(){"working"=>RowState::Working,"asking"=>RowState::Asking,"waiting"=>RowState::Waiting,"idle"=>RowState::Idle,x=>RowState::Unknown(x.into())},s.phase.clone(),s.bead.clone(),s.since,s.phase_since,None)}},
  _=>{let l=live(&r.name,root,processes); (if l.is_empty(){RowState::Dead}else{RowState::Up},None,None,None,None,None)}
 }; let sessions=live(&r.name,root,processes).len(); let mins=since.map(|t|(now-t).num_minutes()).unwrap_or(0); FleetRow{name:r.name.clone(),role:r.role.clone(),state,phase,bead,since,phase_since,for_text:format!("{}m",mins),sessions,stop_requested:input.map(|x|x.stop_requested).unwrap_or(false),unverified,diagnostic:diag}
 }).collect()
}
fn excluded(b:&Bead)->bool { b.issue_type=="epic" || b.issue_type=="event" || b.status=="blocked" || (b.status=="closed" && !b.labels.iter().any(|x|x=="verified")) }
pub fn partition_beads(mut bs:Vec<Bead>)->WorkBuckets { let mut w=WorkBuckets::default(); bs.retain(|b|!excluded(b)); for b in bs { if b.labels.iter().any(|x|x=="human"){w.paused.push(b)} else if b.status=="closed"{w.merged.push(b)} else if b.assignee.is_some(){w.claimed.push(b)} else if b.labels.iter().any(|x|x=="planned"){w.planned.push(b)} else if b.labels.iter().any(|x|x.starts_with("planning")){w.being_planned.push(b)} else {w.unplanned.push(b)} } w }

#[cfg(test)] mod tests {
 use super::*;
 #[test] fn session_marker_cases_match_all_rows(){assert!(session_marker_matches("This session is Xavier of the cerebro fleet rooted at /r/.","Xavier",Path::new("/r")));assert!(!session_marker_matches("This session is Xavierly of the cerebro fleet rooted at /r/.","Xavier",Path::new("/r")));}
 #[test] fn same_named_session_in_another_consumer_is_not_live(){assert!(!session_marker_matches("This session is Xavier of the cerebro fleet rooted at /other/.","Xavier",Path::new("/r")));}
 #[test] fn marker_without_state_is_up_for_every_agent_kind(){let rs=vec![RosterEntry{name:"A".into(),role:"x".into(),kind:AgentKind::Interactive}];let mut s=BTreeMap::new();s.insert("A".into(),StateInput{observation:StateObservation::Missing,stop_requested:false});let p=vec![ProcessRow{pid:1,ppid:None,args:"This session is A of the cerebro fleet rooted at /r/.".into()}];assert_eq!(derive_fleet(&rs,&s,&p,Path::new("/r"),Utc::now())[0].state,RowState::Up);}
 #[test] fn wrapper_processes_count_once(){let p="1 0 This session is A of the cerebro fleet rooted at /r/.\n2 1 This session is A of the cerebro fleet rooted at /r/.";assert_eq!(super::live("A",Path::new("/r"),&parse_processes(p).unwrap()).len(),1);}
}

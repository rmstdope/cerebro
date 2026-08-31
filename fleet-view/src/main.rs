use std::io;
use crossterm::{execute,event::{self,Event,KeyCode},terminal::{enable_raw_mode,disable_raw_mode,EnterAlternateScreen,LeaveAlternateScreen}};
use ratatui::{backend::CrosstermBackend,Terminal,widgets::Paragraph};
fn main()->Result<(),Box<dyn std::error::Error>> {
 for key in ["CEREBRO_CONSUMER_ROOT","CEREBRO_CONSUMER_SHARED_ROOT","CEREBRO_CONSUMER_MOUNT","CEREBRO_SCRIPTS"] { if std::env::var_os(key).is_none(){ return Err(format!("missing {key}").into()); } }
 enable_raw_mode()?; let mut out=io::stdout(); execute!(out,EnterAlternateScreen)?;
 let mut t=Terminal::new(CrosstermBackend::new(out))?;
 loop { t.draw(|f|f.render_widget(Paragraph::new("Cerebro — read-only"),f.area()))?; if event::poll(std::time::Duration::from_millis(250))? { if let Event::Key(k)=event::read()? { if matches!(k.code,KeyCode::Char('q')|KeyCode::Esc){break} } } }
 disable_raw_mode()?; execute!(t.backend_mut(),LeaveAlternateScreen)?; Ok(())
}

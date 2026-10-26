import ci
import project_ci

pub fn main() {
  ci.serve(project_ci.definition())
}

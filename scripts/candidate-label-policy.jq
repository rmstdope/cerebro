def without_verifier_only_label($label):
  select((.labels // []) | index($label) | not);

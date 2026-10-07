def without_verifier_only_label($label):
  select((.labels // []) | index($label) | not);
# True when the bead carries any of the past-UX labels (`candidate-label-policy.sh`). `index` gives
# a position, and position 0 is truthy in jq, so `any` reads it correctly.
def past_ux($past):
  (.labels // []) as $labels | any($past[]; . as $label | $labels | index($label));

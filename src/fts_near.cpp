#include "fts_near.hpp"

#include "duckdb/common/vector/vector_writer.hpp"

namespace duckdb {

// Positions arrive unordered with the term id of each posting; the result is
// the smallest per-term count of positions within width of a match end.
static int64_t NearTf(const vector<int64_t> &positions,
                      const vector<int64_t> &term_ids, int64_t slot_count,
                      int64_t width) {
  if (slot_count <= 0 || width < 0) {
    return 0;
  }
  vector<std::pair<int64_t, int64_t>> postings;
  postings.reserve(positions.size());
  for (idx_t i = 0; i < positions.size(); i++) {
    postings.emplace_back(positions[i], term_ids[i]);
  }
  std::sort(postings.begin(), postings.end());
  vector<int64_t> unique_ids;
  vector<idx_t> slots;
  slots.reserve(postings.size());
  for (const auto &posting : postings) {
    auto term_id = posting.second;
    idx_t slot = unique_ids.size();
    for (idx_t known = 0; known < unique_ids.size(); known++) {
      if (unique_ids[known] == term_id) {
        slot = known;
        break;
      }
    }
    if (slot == unique_ids.size()) {
      unique_ids.push_back(term_id);
    }
    slots.push_back(slot);
  }
  if (NumericCast<int64_t>(unique_ids.size()) < slot_count) {
    return 0;
  }
  auto found_count = unique_ids.size();
  vector<int64_t> last(found_count, NumericLimits<int64_t>::Minimum());
  vector<int64_t> ends;
  idx_t filled = 0;
  for (idx_t i = 0; i < postings.size(); i++) {
    if (last[slots[i]] == NumericLimits<int64_t>::Minimum()) {
      filled++;
    }
    last[slots[i]] = postings[i].first;
    if (filled < found_count) {
      continue;
    }
    auto min_last = last[0];
    for (idx_t s = 1; s < found_count; s++) {
      min_last = MinValue(min_last, last[s]);
    }
    if (min_last >= postings[i].first - width) {
      ends.push_back(postings[i].first);
    }
  }
  if (ends.empty()) {
    return 0;
  }
  vector<int64_t> matched(found_count, 0);
  auto next_end = NumericLimits<int64_t>::Maximum();
  idx_t end_index = ends.size();
  for (idx_t i = postings.size(); i > 0; i--) {
    auto position = postings[i - 1].first;
    while (end_index > 0 && ends[end_index - 1] >= position) {
      next_end = ends[end_index - 1];
      end_index--;
    }
    if (next_end != NumericLimits<int64_t>::Maximum() &&
        next_end - position <= width) {
      matched[slots[i - 1]]++;
    }
  }
  auto tf = matched[0];
  for (idx_t s = 1; s < found_count; s++) {
    tf = MinValue(tf, matched[s]);
  }
  return tf;
}

static void NearTfFunction(DataChunk &args, ExpressionState &state,
                           Vector &result) {
  auto position_lists = args.data[0].Values<VectorListType<int64_t>>();
  auto term_id_lists = args.data[1].Values<VectorListType<int64_t>>();
  auto slot_counts = args.data[2].Values<int64_t>();
  auto widths = args.data[3].Values<int64_t>();

  result.SetVectorType(VectorType::FLAT_VECTOR);
  auto writer = FlatVector::Writer<int64_t>(result, args.size());
  for (idx_t i = 0; i < args.size(); i++) {
    auto position_entry = position_lists[i];
    auto term_id_entry = term_id_lists[i];
    auto slot_count = slot_counts[i];
    auto width = widths[i];
    if (!position_entry.IsValid() || !term_id_entry.IsValid() ||
        !slot_count.IsValid() || !width.IsValid()) {
      writer.WriteNull();
      continue;
    }
    vector<int64_t> positions;
    vector<int64_t> term_ids;
    positions.reserve(position_entry.GetListLength());
    term_ids.reserve(term_id_entry.GetListLength());
    bool entries_valid = true;
    for (const auto value : position_entry.GetChildValues()) {
      if (!value.IsValid()) {
        entries_valid = false;
        break;
      }
      positions.push_back(value.GetValue());
    }
    for (const auto value : term_id_entry.GetChildValues()) {
      if (!value.IsValid()) {
        entries_valid = false;
        break;
      }
      term_ids.push_back(value.GetValue());
    }
    if (!entries_valid || positions.size() != term_ids.size()) {
      writer.WriteNull();
      continue;
    }
    writer.WriteValue(
        NearTf(positions, term_ids, slot_count.GetValue(), width.GetValue()));
  }
}

ScalarFunction GetFTSNearTfFunction() {
  ScalarFunction function("fts_near_tf",
                          {LogicalType::LIST(LogicalType::BIGINT),
                           LogicalType::LIST(LogicalType::BIGINT),
                           LogicalType::BIGINT, LogicalType::BIGINT},
                          LogicalType::BIGINT, NearTfFunction);
  return function;
}

} // namespace duckdb

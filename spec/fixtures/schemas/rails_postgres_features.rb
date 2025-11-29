# Enable extensions
# enable_extension "hstore"
# enable_extension "uuid-ossp"
# enable_extension "citext"
# enable_extension "ltree"
# enable_extension "pgcrypto"

create_table "all_types", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade, comment: "Table with all standard types" do |t|
  t.string "string_col"
  t.text "text_col"
  t.integer "integer_col"
  t.float "float_col"
  t.decimal "decimal_col", precision: 10, scale: 2
  t.datetime "datetime_col"
  t.time "time_col"
  t.date "date_col"
  t.binary "binary_col"
  t.boolean "boolean_col", default: false
  t.bigint "bigint_col"
  t.json "json_col"
  t.jsonb "jsonb_col"
  t.inet "inet_col"
  t.cidr "cidr_col"
  t.macaddr "macaddr_col"
  t.hstore "hstore_col"
  t.uuid "uuid_col"
  t.interval "interval_col"
  t.xml "xml_col"
  t.bit "bit_col", limit: 1
  t.bit_varying "bit_varying_col", limit: 10
  t.money "money_col"
  t.citext "citext_col"
  t.ltree "ltree_col"
  t.timestamps
end

create_table "array_types", force: :cascade do |t|
  t.string "string_array", array: true
  t.integer "integer_array", array: true
  t.text "text_array", array: true
  t.boolean "boolean_array", array: true
  t.jsonb "jsonb_array", array: true
end

create_table "range_types", force: :cascade do |t|
  t.int4range "int4_range"
  t.int8range "int8_range"
  t.numrange "num_range"
  t.tsrange "ts_range"
  t.tstzrange "tstz_range"
  t.daterange "date_range"
end

create_table "constraints_table", force: :cascade do |t|
  t.integer "price"
  t.integer "discount"
  t.check_constraint "price > 0", name: "price_check"
  t.check_constraint "discount < price", name: "discount_check"
end

create_table "exclusion_constraints_table", force: :cascade do |t|
  t.daterange "validity"
  t.integer "room_id"
  t.exclusion_constraint "validity WITH &&, room_id WITH =", using: :gist, name: "exclude_overlapping_bookings"
end

create_table "unique_constraints_table", force: :cascade do |t|
  t.integer "position"
  t.integer "group_id"
  t.unique_constraint ["position", "group_id"], name: "unique_position_per_group", deferrable: :deferred
  t.unique_constraint ["position"], name: "unique_position_nulls_not_distinct", nulls_not_distinct: true
end

create_table "indexed_table", force: :cascade do |t|
  t.string "col1"
  t.string "col2"
  t.text "description"
  t.jsonb "data"
  t.integer "tenant_id"
  t.boolean "deleted"
end

add_index "indexed_table", ["col1"], name: "index_col1_desc", order: { col1: :desc }
add_index "indexed_table", ["col2"], name: "index_col2_partial", where: "(deleted IS FALSE)"
add_index "indexed_table", ["data"], name: "index_data_gin", using: :gin
add_index "indexed_table", ["tenant_id", "col1"], name: "index_include", include: ["col2"]
add_index "indexed_table", ["col1"], name: "index_opclass", opclass: { col1: :text_pattern_ops }
add_index "indexed_table", ["col2"], name: "index_unique_nulls_not_distinct", unique: true, nulls_not_distinct: true

create_table "parent_table", force: :cascade do |t|
  t.integer "category_id"
end

create_table "child_table", id: false, force: :cascade, options: "INHERITS (parent_table)" do |t|
  t.string "child_attr"
end

# Foreign keys
create_table "authors", force: :cascade do |t|
  t.string "name"
end

create_table "books", force: :cascade do |t|
  t.bigint "author_id"
end

add_foreign_key "books", "authors", on_delete: :cascade, on_update: :restrict

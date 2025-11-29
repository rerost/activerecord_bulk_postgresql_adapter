create_table "users", force: :cascade do |t|
  t.string "name", null: false
  t.string "email", null: false
  t.integer "age"
  t.boolean "active", default: true
  t.timestamps
end

add_index "users", ["email"], name: "index_users_on_email", unique: true
add_index "users", ["name"], name: "index_users_on_name"

create_table "posts", force: :cascade do |t|
  t.string "title", null: false
  t.text "body"
  t.bigint "user_id", null: false
  t.timestamps
end

add_foreign_key "posts", "users"
add_index "posts", ["user_id"], name: "index_posts_on_user_id"

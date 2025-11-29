create_table "products", force: :cascade, comment: "Product table" do |t|
  t.string "name", null: false
  t.decimal "price", precision: 10, scale: 2, null: false
  t.jsonb "metadata", default: {}
  t.timestamps
end

add_index "products", ["metadata"], name: "index_products_on_metadata", using: :gin

create_table "orders", force: :cascade do |t|
  t.bigint "user_id"
  t.decimal "total", precision: 10, scale: 2
  t.string "status", default: "pending"
  t.timestamps
end

create_table "order_items", force: :cascade do |t|
  t.bigint "order_id", null: false
  t.bigint "product_id", null: false
  t.integer "quantity", default: 1
  t.decimal "price", precision: 10, scale: 2
end

add_foreign_key "order_items", "orders"
add_foreign_key "order_items", "products"
add_index "order_items", ["order_id", "product_id"], name: "index_order_items_on_order_id_and_product_id", unique: true

require "spec"

describe "Intrinsics.prefetch" do
  it "compiles and runs as a hint" do
    buffer = uninitialized UInt8[64]
    Intrinsics.prefetch(buffer.to_unsafe.as(Void*))
    Intrinsics.prefetch(buffer.to_unsafe.as(Void*), locality: 0)
    Intrinsics.prefetch(buffer.to_unsafe.as(Void*), locality: 3, read_data: false)
  end
end

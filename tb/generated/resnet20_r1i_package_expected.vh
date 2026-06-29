// Generated package-faithful R1i expected values and payloads.
localparam integer R1G_COMPARE_TASK_COUNT = 4;
localparam integer R1G_MAX_COMPARE_BYTES = 16384;
localparam signed [31:0] R1G_CONV1_REF_MAC_BEFORE_BIAS = 0;
localparam signed [31:0] R1G_CONV1_REF_BIAS = 0;
localparam signed [31:0] R1G_CONV1_REF_ACC_AFTER_BIAS = 0;
localparam signed [7:0] R1G_CONV1_REF_OUTPUT_I8 = 0;
task init_r1g_compare_expected;
integer i;
begin
  for (i=0;i<8;i=i+1) begin r1g_compare_bytes[i]=0; r1g_expected_checksum[i]=0; r1g_weight_payload_bytes[i]=0; r1g_bias_payload_bytes[i]=0; end
  $readmemh("tb/generated/resnet20_r1i_package_slice/input_image.memh", r1i_load_byte);
  for (i=0;i<3072;i=i+1) r1i_input_payload[i] = r1i_load_byte[i];
  r1i_input_payload_bytes = 3072;
  r1g_reference_name[0] = "conv1";
  r1g_compare_bytes[0] = 16384;
  r1g_expected_checksum[0] = 32'h482186f6;
  $readmemh("tb/generated/resnet20_r1i_package_slice/conv1_expected.memh", r1i_load_byte);
  for (i=0;i<16384;i=i+1) r1g_expected_byte[0][i] = r1i_load_byte[i];
  r1g_weight_payload_bytes[0] = 432;
  r1g_bias_payload_bytes[0] = 64;
  $readmemh("tb/generated/resnet20_r1i_package_slice/conv1_weights.memh", r1i_load_byte);
  for (i=0;i<432;i=i+1) r1g_weight_payload_byte[0][i] = r1i_load_byte[i];
  $readmemh("tb/generated/resnet20_r1i_package_slice/conv1_bias_bytes.memh", r1i_load_byte);
  for (i=0;i<64;i=i+1) r1g_bias_payload_byte[0][i] = r1i_load_byte[i];
  r1g_reference_name[1] = "layer1.0.conv1";
  r1g_compare_bytes[1] = 16384;
  r1g_expected_checksum[1] = 32'h42a00bb5;
  $readmemh("tb/generated/resnet20_r1i_package_slice/layer1_0_conv1_expected.memh", r1i_load_byte);
  for (i=0;i<16384;i=i+1) r1g_expected_byte[1][i] = r1i_load_byte[i];
  r1g_weight_payload_bytes[1] = 2304;
  r1g_bias_payload_bytes[1] = 64;
  $readmemh("tb/generated/resnet20_r1i_package_slice/layer1_0_conv1_weights.memh", r1i_load_byte);
  for (i=0;i<2304;i=i+1) r1g_weight_payload_byte[1][i] = r1i_load_byte[i];
  $readmemh("tb/generated/resnet20_r1i_package_slice/layer1_0_conv1_bias_bytes.memh", r1i_load_byte);
  for (i=0;i<64;i=i+1) r1g_bias_payload_byte[1][i] = r1i_load_byte[i];
  r1g_reference_name[2] = "layer1.0.conv2";
  r1g_compare_bytes[2] = 16384;
  r1g_expected_checksum[2] = 32'h12b975e6;
  $readmemh("tb/generated/resnet20_r1i_package_slice/layer1_0_conv2_expected.memh", r1i_load_byte);
  for (i=0;i<16384;i=i+1) r1g_expected_byte[2][i] = r1i_load_byte[i];
  r1g_weight_payload_bytes[2] = 2304;
  r1g_bias_payload_bytes[2] = 64;
  $readmemh("tb/generated/resnet20_r1i_package_slice/layer1_0_conv2_weights.memh", r1i_load_byte);
  for (i=0;i<2304;i=i+1) r1g_weight_payload_byte[2][i] = r1i_load_byte[i];
  $readmemh("tb/generated/resnet20_r1i_package_slice/layer1_0_conv2_bias_bytes.memh", r1i_load_byte);
  for (i=0;i<64;i=i+1) r1g_bias_payload_byte[2][i] = r1i_load_byte[i];
  r1g_reference_name[3] = "layer1.0.add";
  r1g_compare_bytes[3] = 16384;
  r1g_expected_checksum[3] = 32'h60a5b07f;
  $readmemh("tb/generated/resnet20_r1i_package_slice/layer1_0_add_expected.memh", r1i_load_byte);
  for (i=0;i<16384;i=i+1) r1g_expected_byte[3][i] = r1i_load_byte[i];
end
endtask

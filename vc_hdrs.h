#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <dlfcn.h>
#include "svdpi.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef _VC_TYPES_
#define _VC_TYPES_
/* common definitions shared with DirectC.h */

typedef unsigned int U;
typedef unsigned char UB;
typedef unsigned char scalar;
typedef struct { U c; U d;} vec32;

#define scalar_0 0
#define scalar_1 1
#define scalar_z 2
#define scalar_x 3

extern long long int ConvUP2LLI(U* a);
extern void ConvLLI2UP(long long int a1, U* a2);
extern long long int GetLLIresult();
extern void StoreLLIresult(const unsigned int* data);
typedef struct VeriC_Descriptor *vc_handle;

#ifndef SV_3_COMPATIBILITY
#define SV_STRING const char*
#else
#define SV_STRING char*
#endif

#endif /* _VC_TYPES_ */


 extern int uvm_hdl_check_path(/* INPUT */const char* path);

 extern int uvm_hdl_deposit(/* INPUT */const char* path, const /* INPUT */svLogicVecVal *value);

 extern int uvm_hdl_force(/* INPUT */const char* path, const /* INPUT */svLogicVecVal *value);

 extern int uvm_hdl_release_and_read(/* INPUT */const char* path, /* INOUT */svLogicVecVal *value);

 extern int uvm_hdl_release(/* INPUT */const char* path);

 extern int uvm_hdl_read(/* INPUT */const char* path, /* OUTPUT */svLogicVecVal *value);

 extern SV_STRING uvm_hdl_read_string(/* INPUT */const char* path);

 extern int uvm_memory_load(/* INPUT */const char* nid, /* INPUT */const char* scope, /* INPUT */const char* fileName, /* INPUT */const char* radix, /* INPUT */const char* startaddr, /* INPUT */const char* endaddr, /* INPUT */const char* types);

 extern SV_STRING uvm_dpi_get_next_arg_c(/* INPUT */int init);

 extern SV_STRING uvm_dpi_get_tool_name_c();

 extern SV_STRING uvm_dpi_get_tool_version_c();

 extern void* uvm_dpi_regcomp(/* INPUT */const char* regex);

 extern int uvm_dpi_regexec(/* INPUT */void* preg, /* INPUT */const char* str);

 extern void uvm_dpi_regfree(/* INPUT */void* preg);

 extern int uvm_re_match(/* INPUT */const char* re, /* INPUT */const char* str);

 extern void uvm_dump_re_cache();

 extern SV_STRING uvm_glob_to_re(/* INPUT */const char* glob);

 extern void m__uvm_report_dpi(/* INPUT */int severity, /* INPUT */const char* id, /* INPUT */const char* message, /* INPUT */int verbosity, /* INPUT */const char* filename, /* INPUT */int line);

 extern int npu_conv_ref(const /* INPUT */svOpenArrayHandle input_data, const /* INPUT */svOpenArrayHandle weight_data, const /* OUTPUT */svOpenArrayHandle output_data, /* INPUT */int input_h, /* INPUT */int input_w, /* INPUT */int input_c, /* INPUT */int output_c, /* INPUT */int kernel_h, /* INPUT */int kernel_w, /* INPUT */int stride, 
/* INPUT */int padding);

 extern int npu_fc_ref(const /* INPUT */svOpenArrayHandle input_data, const /* INPUT */svOpenArrayHandle weight_data, const /* OUTPUT */svOpenArrayHandle output_data, /* INPUT */int input_c, /* INPUT */int output_c);

 extern int npu_pool_ref(const /* INPUT */svOpenArrayHandle input_data, const /* OUTPUT */svOpenArrayHandle output_data, /* INPUT */int input_h, /* INPUT */int input_w, /* INPUT */int channels);

 extern int npu_requant_ref(const /* INPUT */svOpenArrayHandle input_data, const /* OUTPUT */svOpenArrayHandle output_data, /* INPUT */int count, /* INPUT */int multiplier, /* INPUT */int shift);

 extern int npu_bias_ref(const /* INPUT */svOpenArrayHandle input_data, const /* INPUT */svOpenArrayHandle bias_data, const /* OUTPUT */svOpenArrayHandle output_data, /* INPUT */int count, /* INPUT */int relu_en, /* INPUT */int requant_en, /* INPUT */int multiplier, /* INPUT */int shift);

 extern int npu_add_ref(const /* INPUT */svOpenArrayHandle src0_data, const /* INPUT */svOpenArrayHandle src1_data, const /* OUTPUT */svOpenArrayHandle output_data, /* INPUT */int count, /* INPUT */int src0_multiplier, /* INPUT */int src0_shift, /* INPUT */int src1_multiplier, /* INPUT */int src1_shift, /* INPUT */int out_multiplier, /* INPUT */int out_shift, 
/* INPUT */int relu_en, /* INPUT */int requant_en);

 extern int npu_gap_ref(const /* INPUT */svOpenArrayHandle input_data, const /* OUTPUT */svOpenArrayHandle output_data, /* INPUT */int channels, /* INPUT */int multiplier, /* INPUT */int shift);
void SdisableFork();

#ifdef __cplusplus
}
#endif


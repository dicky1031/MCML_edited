//#include <cutil.h> //cuda toolkit below 5.0 support for CUDA_SAFE_CALL()
#include <iostream>
#include <fstream>
#include <stdio.h>
#include <math.h>
#include <time.h>
#include <curand.h>
#include <curand_kernel.h>
#include <cuda_runtime.h>
//#include <helper_cuda.h>
#include <memory>

using namespace std;

// DEFINES 
#define USE_PRESET_GPU false // use the preseted blocks and threads number, otherwise, use the setting calculate by GPU

#define NUM_BLOCKS 5*16//20*16 //5*16 //dimGrid //Keep numblocks a multiple of the #MP's of the GPU (8800GT=14MP)
// MP= multiprocessor, 1080=20MP, 1080ti=28MP

//The register usage varies with platform. 64-bit Linux and 32.bit Windows XP have been tested.
#ifdef __linux__ //uses 25 registers per thread (64-bit)
#define NUM_THREADS_PER_BLOCK 256 //Keep above 192 to eliminate global memory access overhead However, keep low to allow enough registers per thread
#define NUM_THREADS NUM_BLOCKS*NUM_THREADS_PER_BLOCK
#elif _WIN64
#define NUM_THREADS_PER_BLOCK 256  //256 //dimBlock
#define NUM_THREADS NUM_BLOCKS*NUM_THREADS_PER_BLOCK
#else //uses 26 registers per thread
#define NUM_THREADS_PER_BLOCK 288 //Keep above 192 to eliminate global memory access overhead However, keep low to allow enough registers per thread
#define NUM_THREADS NUM_BLOCKS*NUM_THREADS_PER_BLOCK   
#endif


#define MCML_VERSION "3.02"
#define Last_Update_Date "2020/06/13"

#define NUM_LAYER 5
#define PRESET_NUM_LAYER 10
#define NUMSTEPS_GPU       50000
#define PI                 3.141592654f
#define RPI                0.318309886f
#define STR_LEN            200
#define NORMAL             0                    // 1: normal, 0: oblique
#define PRESET_NUM_DETECTOR 30
//#define ANGLE              0   //(NORMAL ? 0:0)      // normal: 0 degree, oblique: 0 degree  by CY

//#define NAOfSource         (NORMAL ? 0.37:0.37) // skin: (NORMAL ? 0.26:0.26)
//#define NAOfDetector       (NORMAL ? 0.12:0.12) // skin: (NORMAL ? 0.26:0.26)
#define n_detector         1.457 // for now, the value is not use, and detector n is set to the value of upper_n
#define n_source           1.457//1.457//1.457//1.61 //YU-modified
//#define illumination_r     0.075 //0.075		//radius //Wang-modified //skin:0.025  IJV:0.075
//#define collect_r          0.015 // skin: 0.01
//#define NUMBER_PHOTONS     50000000 //1000000000//50000000//400000000 -skin
//#define NUMBER_SIMULATION  1//42//31//54//36  //IJV:36 skin:4

//#define WEIGHT 0.0001f
#define WEIGHTI 429497u //0xFFFFFFFFu*WEIGHT
#define CHANCE 0.1f

#define detected_temp_size 7000 //number of photon should be detected
#define SDS_detected_temp_size 20
#define max_scatter_time 10000 // the max times a photon can scatter, if larger than this value, the weight will be too small, and don't need to continue simulate it

// define the absorbance array
#define record_dr 0.01f
#define record_dz 0.01f
#define record_nr 1000
#define record_nz 500

// define the percentage of change mua to calculate average pathlength
#define mua_change_ratio 0.001 // 0.1%

#define max_GPU_name_length 100
#define Print_GPU_info true

// TYPEDEFS
typedef struct __align__(16)
{
	float z_min;		// Layer z_min [cm]
	float z_max;		// Layer z_max [cm]
	float mutr;			// Reciprocal mu_total [cm]
	float mua;			// Absorption coefficient [1/cm]
	float g;			// Anisotropy factor [-]
	float n;			// Refractive index [-]
}LayerStruct;

typedef struct __align__(16)
{
	float x;		// Global x coordinate [cm]
	float y;		// Global y coordinate [cm]
	float z;		// Global z coordinate [cm]
	float dx;		// (Global, normalized) x-direction
	float dy;		// (Global, normalized) y-direction
	float dz;		// (Global, normalized) z-direction
	float weight;			// Photon weight
	int layer;				// Current layer
	bool first_scatter; // flag of first scatter
	int scatter_event; // record howmany time the photon had been scattered

	curandState state_seed; // store the initial curandState for the photon
	curandState state_run; // store the current state of curand

}PhotonStruct;

typedef struct
{
	float raduis;
	float NA;
	float position;
	float angle;
}DetectorInfoStruct;

typedef struct
{
	unsigned long long number_of_photons;
	unsigned int num_layers;
	unsigned int num_detector;
	float start_weight;
	float detector_reflectance; // the reflectance change of detector
	bool source_probe_oblique; // if the source probe is oblique
	bool detector_probe_oblique; // if the detector probes are oblique
	LayerStruct* layers;
	DetectorInfoStruct* detInfo;
	float* critical_arr; // the array for critical angle for each detector
}SimulationStruct;

typedef struct
{
	int detected_photon_counter; // record how many photon had been detected by this fiber in one iteration, should not exceed SDS_detected_temp_size
	float data[SDS_detected_temp_size]; // the photon weight detected by this probe
	int detected_SDS_number[SDS_detected_temp_size]; // record which SDS detected the photon
	curandState detected_state[SDS_detected_temp_size]; // store the initial state of detected photons
}Fibers;

typedef struct
{
	bool have_detected;
	float data; // the photon weight detected by this probe
	float layer_pathlength[PRESET_NUM_LAYER]; // record the pathlength in each layer for detected photon
	int scatter_event; // record howmany time the photon had been scattered
	int detected_SDS_number; // record which SDS detected the photon
}Fibers_Replay;



typedef struct
{
	Fibers* f;
	PhotonStruct* p;					// Pointer to structure array containing all the photon data
	unsigned int* thread_active;		// Pointer to the array containing the thread active status
	unsigned long long* num_terminated_photons;	//Pointer to a scalar keeping track of the number of terminated photons
	curandState*  state;

	unsigned long long* AA_rz;
	unsigned long long* AA0_z;
	unsigned long long* R;

}MemStruct;

typedef struct // additional data structure for record fluence rate, pathlength
{
	Fibers_Replay* f_r;

	unsigned long long* A_rz;			// array to store absorbance, a nz by nr array
	unsigned long long* A0_z;			// array to store the first scatter absorbance

	
}MemStruct_Replay;

typedef struct
{
	float* all;
	float* prob;
	float* cumf;
}G_Array;

typedef struct
{
	clock_t time1, time2, time3;
	int* total_SDS_detect_num;
	unsigned long long number_of_photons;
	char GPU_name[max_GPU_name_length];
}SummaryStruct;

typedef struct
{
	char name[max_GPU_name_length];
	int id;                       // global index of the GPU, starting from 0
	int major;                    // major version of the compute capability
	int minor;                    // minor version of the compute capability
	size_t globalmem;             // size of the global memory in the GPU
	size_t constmem;              // size of the constant memory in the GPU
	size_t sharedmem;             // size of the shared memory in the GPU
	int regcount;                 // size of the register file in the GPU
	int clock;                    // clock in Hz of the GPU processor
	int MPs;                      // number of multi processors
	int core;                     // number of stream processors
	int autoblock;                // optimized number of blocks to launch
	int autothreadpb;             // optimized number of threads per block
	int autototalthread;          // optimized number of total threads to launch
	int maxMPthread;              // maximum thread number per multi-processor
} GPUInfo;

typedef struct
{
	bool do_replay;	                    // replay the detected photon or not
	bool do_output_A_arr;               // output the detected Absorbance array or not
	bool output_each_pathlength;        // output the pathlength of each detected photon or not
	bool do_output_average_pathlength;  // output the average pathlength of the detected photon or not
	bool do_output_bin;                 // output the pathlength file in binary format ot not
	int GPU_select_to_run;              // the index of selected GPU
	
	bool do_output_reflectance;
	bool do_output_AA_arr;

} SimOptions;

__device__ __constant__ unsigned long long num_photons_dc[1];
__device__ __constant__ unsigned int n_layers_dc[1];
__device__ __constant__ unsigned int num_detector_dc[1];
__device__ __constant__ float start_weight_dc[1];
__device__ __constant__ float detector_reflectance_dc[1];
__device__ __constant__ LayerStruct layers_dc[PRESET_NUM_LAYER + 2];
__device__ __constant__ DetectorInfoStruct detInfo_dc[PRESET_NUM_DETECTOR + 1];
__device__ __constant__ float critical_angle_dc[PRESET_NUM_DETECTOR + 1];
__device__ __constant__ bool source_probe_oblique_dc[1];
__device__ __constant__ bool detector_probe_oblique_dc[1];

// extern __device__ __constant__ unsigned long long num_photons_dc[1];
// extern __device__ __constant__ unsigned int n_layers_dc[1];
// extern __device__ __constant__ unsigned int num_detector_dc[1];
// extern __device__ __constant__ float start_weight_dc[1];
// extern __device__ __constant__ float detector_reflectance_dc[1];
// extern __device__ __constant__ LayerStruct layers_dc[PRESET_NUM_LAYER + 2];
// extern __device__ __constant__ DetectorInfoStruct detInfo_dc[PRESET_NUM_DETECTOR + 1];
// extern __device__ __constant__ float critical_angle_dc[PRESET_NUM_DETECTOR + 1];
// extern __device__ __constant__ bool source_probe_oblique_dc[1];
// extern __device__ __constant__ bool detector_probe_oblique_dc[1];
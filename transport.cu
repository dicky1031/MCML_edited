#include "header.h"
//#include <helper_cuda.h>	//YU-modified
//#include <helper_string.h>  //YU-modified
//#include <helper_math.h>	//YU-modified
#include <float.h> //for FLT_MAX
#include <vector> // for vector
#include <assert.h>
#include <math.h>

// __device__ __constant__ unsigned long long num_photons_dc[1];
// __device__ __constant__ unsigned int n_layers_dc[1];
// __device__ __constant__ unsigned int num_detector_dc[1];
// __device__ __constant__ float start_weight_dc[1];
// __device__ __constant__ float detector_reflectance_dc[1];
// __device__ __constant__ LayerStruct layers_dc[PRESET_NUM_LAYER + 2];
// __device__ __constant__ DetectorInfoStruct detInfo_dc[PRESET_NUM_DETECTOR + 1];
// __device__ __constant__ float critical_angle_dc[PRESET_NUM_DETECTOR + 1];
// __device__ __constant__ bool source_probe_oblique_dc[1];
// __device__ __constant__ bool detector_probe_oblique_dc[1];

int InitMemStructs(MemStruct* HostMem, MemStruct* DeviceMem, SimulationStruct* sim, int num_of_threads);
int InitMemStructs_replay(MemStruct_Replay* HostMem, MemStruct_Replay* DeviceMem, SimulationStruct* sim, int num_of_threads);
void FreeMemStructs(MemStruct* HostMem, MemStruct* DeviceMem);
void FreeMemStructs_replay(MemStruct_Replay* HostMem, MemStruct_Replay* DeviceMem);
void FreeSimulationStruct(SimulationStruct* sim, int n_simulations);
__global__ void MCd(MemStruct DeviceMem, unsigned long long seed, int num_of_threads, int num_of_threads_per_block);
__global__ void MCd_replay(MemStruct DeviceMem, MemStruct_Replay DeviceMem_Replay, int detected_SDS, int num_of_threads_per_block);
int InitDCMem(SimulationStruct* sim);
int Write_Simulation_Results(MemStruct* HostMem, SimulationStruct* sim, clock_t simulation_time);
int read_simulation_data(char* filename, SimulationStruct** simulations, int ignoreAdetection);
int interpret_arg(int argc, char* argv[], unsigned long long* seed, int* ignoreAdetection);

__device__ void LaunchPhoton(PhotonStruct* p, curandState *state);
__global__ void LaunchPhoton_Global(MemStruct DeviceMem, unsigned long long seed, int num_of_threads_per_block);
__device__ void Spin(PhotonStruct*, float, curandState* state);
__device__ unsigned int Reflect(PhotonStruct*, int, curandState* state);
__device__ unsigned int PhotonSurvive(PhotonStruct*, curandState* state);
__device__ void AtomicAddULL(unsigned long long* address, unsigned int add);
__device__ bool detect(PhotonStruct* p, Fibers* f);
__device__ bool detect_replay(PhotonStruct* p, Fibers* f, int detected_SDS);
__device__ int binarySearch(float *data, float value);
void fiber_initialization(Fibers* f, int num_of_threads);
void fiber_initialization_replay(Fibers_Replay* f_r, SimulationStruct* sim, int num_of_threads);
void output_fiber(SimulationStruct* sim, float* reflectance, char* output); //Wang modified
void output_SDS_pathlength(SimulationStruct* simulation, float ***pathlength_weight_arr, int *temp_SDS_detect_num, int SDS_to_output, bool do_output_bin);
void output_sim_summary(SimulationStruct* simulation, SummaryStruct sumStruc, bool do_replay);
//void calculate_reflectance(Fibers* f, float *result, float (*pathlength_weight_arr)[NUM_LAYER + 1][detected_temp_size], int *total_SDS_detect_num, int *temp_SDS_detect_num);
void calculate_reflectance(Fibers* f, float *result, int* total_SDS_detect_num, vector<vector<curandState>>& detected_state_arr, int num_of_threads);
void calculate_reflectance_replay(Fibers_Replay* f_r, float *result, float ***pathlength_weight_arr, int *temp_SDS_detect_num, int *total_SDS_detect_num, int SDS_should_be, int num_layers, int num_of_threads);
void input_g(int index, G_Array *g);
int InitG(G_Array* HostG, G_Array* DeviceG, int index);
void FreeG(G_Array* HostG, G_Array* DeviceG);

void output_A_rz(SimulationStruct* sim, unsigned long long *data, bool do_output_bin);
void output_A0_z(SimulationStruct* sim, unsigned long long *data, bool do_output_bin);


void output_AA_rz(SimulationStruct* sim, unsigned long long *data, bool do_output_bin);
void output_AA0_z(SimulationStruct* sim, unsigned long long *data, bool do_output_bin);

void output_reflectance(SimulationStruct* sim, unsigned long long *data, bool do_output_bin);

void calculate_average_pathlength(double *average_PL, float ***pathlength_weight_arr, SimulationStruct *sim, int *total_SDS_detect_num);
void output_average_pathlength(SimulationStruct* sim, double *average_PL);


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

__device__ float rn_gen(curandState *s)
{
	float x = curand_uniform(s);
	return x;
}

void DoOneSimulation(SimulationStruct* simulation, int index, char* output, SimOptions simOpt, GPUInfo** GPUs)
{
	SummaryStruct sumStruc;
	sumStruc.time1 = clock(); // tic
	sumStruc.number_of_photons = simulation->number_of_photons;
	strncpy(sumStruc.GPU_name, (*GPUs)[simOpt.GPU_select_to_run].name, max_GPU_name_length);

	vector<vector<curandState>> detected_state_arr(simulation->num_detector); // the state for detected photon in curand
	int *total_SDS_detect_num = new int[simulation->num_detector]; // record number fo detected photon by each detector
	float *reflectance = new float[simulation->num_detector]; //record reflectance of fibers
	for (int d = 0; d < simulation->num_detector; d++) {
		total_SDS_detect_num[d] = 0;
		reflectance[d] = 0;
	}

	unsigned long long seed = time(NULL);
	srand(seed); // set random seed for main loop

	int num_of_threads_per_block;
	int num_of_blocks;
	int num_of_threads;

	if (USE_PRESET_GPU)
	{
		num_of_blocks = NUM_BLOCKS;
		num_of_threads_per_block = NUM_THREADS_PER_BLOCK;
		num_of_threads = NUM_THREADS;
	}
	else
	{
		num_of_blocks = (*GPUs)[simOpt.GPU_select_to_run].autoblock*(*GPUs)[simOpt.GPU_select_to_run].MPs;
		num_of_threads_per_block = (*GPUs)[simOpt.GPU_select_to_run].autothreadpb;
		num_of_threads = num_of_blocks*num_of_threads_per_block;
	}

	dim3 dimBlock(num_of_threads_per_block);	printf("NUM_THREADS_PER_BLOCK\t%d\n", num_of_threads_per_block);
	dim3 dimGrid(num_of_blocks);				printf("NUM_BLOCKS\t%d\n", num_of_blocks);
	
	MemStruct DeviceMem;
	MemStruct HostMem;
	unsigned int threads_active_total = 1;
	unsigned int i, ii;

	cudaError_t cudastat;

	InitMemStructs(&HostMem, &DeviceMem, simulation, num_of_threads);
	
	InitDCMem(simulation);
	
	LaunchPhoton_Global << <dimGrid, dimBlock >> >(DeviceMem, seed, num_of_threads_per_block);
	cudaThreadSynchronize(); //CUDA_SAFE_CALL( cudaThreadSynchronize() ); // Wait for all threads to finish
	cudastat = cudaGetLastError(); // Check if there was an error
	if (cudastat)printf("Error code=%i, %s.\n", cudastat, cudaGetErrorString(cudastat));

	i = 0;

	// run the first time to find the photons can be detected
	while (threads_active_total>0)
	{
		i++;
		fiber_initialization(HostMem.f, num_of_threads); //Wang modified
																//printf("Size of Fibers\t%d\n",sizeof(Fibers));
		cudaMemcpy(DeviceMem.f, HostMem.f, num_of_threads * sizeof(Fibers), cudaMemcpyHostToDevice); //malloc sizeof(FIbers) equals to 13*(5*4)

																								  //run the kernel
		seed = rand(); // get seed for MCD
		MCd <<<dimGrid, dimBlock >>>(DeviceMem, seed, num_of_threads, num_of_threads_per_block);
		//cout << "after MCd\n";
		cudaThreadSynchronize(); //CUDA_SAFE_CALL( cudaThreadSynchronize() ); // Wait for all threads to finish
		cudastat = cudaGetLastError(); // Check if there was an error
		if (cudastat)printf("Error code=%i, %s.\n", cudastat, cudaGetErrorString(cudastat));

		// Copy thread_active from device to host, later deleted
		cudaMemcpy(HostMem.thread_active, DeviceMem.thread_active, num_of_threads * sizeof(unsigned int), cudaMemcpyDeviceToHost); //CUDA_SAFE_CALL(cudaMemcpy(HostMem.thread_active,DeviceMem.thread_active,NUM_THREADS*sizeof(unsigned int),cudaMemcpyDeviceToHost) );
		threads_active_total = 0;
		for (ii = 0; ii<num_of_threads; ii++) threads_active_total += HostMem.thread_active[ii];

		cudaMemcpy(HostMem.f, DeviceMem.f, num_of_threads * sizeof(Fibers), cudaMemcpyDeviceToHost); //CUDA_SAFE_CALL(cudaMemcpy(HostMem.f,DeviceMem.f,NUM_THREADS*sizeof(Fibers),cudaMemcpyDeviceToHost));
		//cout << "before cal ref\n";
		calculate_reflectance(HostMem.f, reflectance, total_SDS_detect_num, detected_state_arr, num_of_threads);
		//cout << "after cal ref\n";

		cudaMemcpy(HostMem.num_terminated_photons, DeviceMem.num_terminated_photons, sizeof(unsigned long long), cudaMemcpyDeviceToHost);

		

		printf("\rRun %u, Number of photons terminated %llu, Threads active %u, photon deteced number for SDSs:", i, *HostMem.num_terminated_photons, threads_active_total);
		for (int d = 0; d < simulation->num_detector; d++) {
			printf("\t%d,", total_SDS_detect_num[d]);
		}
		printf("          ");
		//printf("\n");
	}
	cudaMemcpy(HostMem.AA_rz, DeviceMem.AA_rz,  record_nr * record_nz * sizeof(unsigned long long), cudaMemcpyDeviceToHost);
	cudaMemcpy(HostMem.AA0_z, DeviceMem.AA0_z,  record_nz * sizeof(unsigned long long), cudaMemcpyDeviceToHost);

	cudaMemcpy(HostMem.R, DeviceMem.R, sizeof(unsigned long long), cudaMemcpyDeviceToHost);
	if (simOpt.do_output_AA_arr) {
		output_AA_rz(simulation, HostMem.AA_rz, simOpt.do_output_bin); // output the absorbance
		output_AA0_z(simulation, HostMem.AA0_z, simOpt.do_output_bin);
	}
	if (simOpt.do_output_reflectance){
		output_reflectance(simulation,HostMem.R, simOpt.do_output_bin);
	}
	sumStruc.time2 = clock(); // toc
	printf("\nfinish first run, cost %.2f secs\n", (double)(sumStruc.time2 - sumStruc.time1) / CLOCKS_PER_SEC);

	sumStruc.total_SDS_detect_num = new int[simulation->num_detector];
	for (int s = 0; s < simulation->num_detector; s++) {
		sumStruc.total_SDS_detect_num[s] = total_SDS_detect_num[s];
	}

	if (!simOpt.do_replay) { // only output the reflectance
		output_fiber(simulation, reflectance, output);
		output_sim_summary(simulation, sumStruc, simOpt.do_replay);
	}
	else { // replay the detected photons
		// init the memstruct for replay
		MemStruct_Replay HostMem_Replay;
		MemStruct_Replay DeviceMem_Replay;
		InitMemStructs_replay(&HostMem_Replay, &DeviceMem_Replay, simulation, num_of_threads);
		//cout << "after init replay mem\n";

		int *temp_SDS_detect_num = new int[simulation->num_detector]; // record temp number fo detected photon by the detector
		float *replay_reflectance = new float[simulation->num_detector]; //record reflectance of fibers
		//float pathlength_weight_arr[PRESET_NUM_DETECTOR][detected_size][NUM_LAYER + 2]
		float*** pathlength_weight_arr = new float**[simulation->num_detector]; // record the pathlength and weight for each photon, in each layer, and for each detector, also scatter times
		for (int s = 0; s < simulation->num_detector; s++) {
			temp_SDS_detect_num[s] = 0;
			replay_reflectance[s] = 0;
			// init the PL array for this detector
			pathlength_weight_arr[s] = new float*[total_SDS_detect_num[s]]; // record the pathlength and weight for each photon, in each layer, and for each detector, also scatter times
			for (int j = 0; j < total_SDS_detect_num[s]; j++) {
				pathlength_weight_arr[s][j] = new float[simulation->num_layers + 2];
				for (int k = 0; k < simulation->num_layers + 2; k++) {
					pathlength_weight_arr[s][j][k] = 0;
				}
			}

			//printf("\tafter init PL arr for SDS %d\n", s);

			// prepare seeds to copy to device
			int replay_counter = 0;
			while (replay_counter < total_SDS_detect_num[s]) {
				int to_dev_index = 0;
				for (int t = 0; t < num_of_threads; t++) {
					HostMem.thread_active[t] = 0;
				}
				while (to_dev_index < num_of_threads && replay_counter < total_SDS_detect_num[s]) {
					HostMem.state[to_dev_index] = detected_state_arr[s][replay_counter];
					HostMem.thread_active[to_dev_index] = 1;
					replay_counter++;
					to_dev_index++;
				}
				cudaMemcpy(DeviceMem.state, HostMem.state, num_of_threads * sizeof(curandState), cudaMemcpyHostToDevice);
				cudaMemcpy(DeviceMem.thread_active, HostMem.thread_active, num_of_threads * sizeof(unsigned int), cudaMemcpyHostToDevice);
				//printf("\t\tafter copy seeds to device mem\n");

				// init fibers
				fiber_initialization(HostMem.f, num_of_threads);
				cudaMemcpy(DeviceMem.f, HostMem.f, num_of_threads * sizeof(Fibers), cudaMemcpyHostToDevice);
				fiber_initialization_replay(HostMem_Replay.f_r, simulation, num_of_threads);
				cudaMemcpy(DeviceMem_Replay.f_r, HostMem_Replay.f_r, num_of_threads * sizeof(Fibers_Replay), cudaMemcpyHostToDevice);
				//printf("\t\tafter init fibers\n");

				// replay
				MCd_replay << <dimGrid, dimBlock >> > (DeviceMem, DeviceMem_Replay, s, num_of_threads_per_block);
				cudaThreadSynchronize(); // Wait for all threads to finish
				cudastat = cudaGetLastError(); // Check if there was an error
				if (cudastat)printf("Error code=%i, %s.\n", cudastat, cudaGetErrorString(cudastat));
				//printf("\t\tafter replay\n");

				// process result
				cudaMemcpy(HostMem_Replay.f_r, DeviceMem_Replay.f_r, num_of_threads * sizeof(Fibers_Replay), cudaMemcpyDeviceToHost);
				calculate_reflectance_replay(HostMem_Replay.f_r, replay_reflectance, pathlength_weight_arr, temp_SDS_detect_num, total_SDS_detect_num, s + 1, simulation->num_layers, num_of_threads);
				//printf("\t\tafter cal reflectance\n");
			}

		}

		int *backup_SDS_detect_num = new int[simulation->num_detector];
		for (int z = 0; z < simulation->num_detector; z++) {
			backup_SDS_detect_num[z] = temp_SDS_detect_num[z];
		}

		if (simOpt.output_each_pathlength) {
			output_SDS_pathlength(simulation, pathlength_weight_arr, temp_SDS_detect_num, 0, simOpt.do_output_bin);
		}
		if (simOpt.do_output_average_pathlength) {
			double *average_PL = new double[simulation->num_layers * simulation->num_detector];
			calculate_average_pathlength(average_PL, pathlength_weight_arr, simulation, backup_SDS_detect_num);
			output_average_pathlength(simulation, average_PL);
		}

		output_fiber(simulation, replay_reflectance, output);

		// copy the A_rz and A0_z back to host
		cudaMemcpy(HostMem_Replay.A_rz, DeviceMem_Replay.A_rz, simulation->num_detector * record_nr * record_nz * sizeof(unsigned long long), cudaMemcpyDeviceToHost);
		cudaMemcpy(HostMem_Replay.A0_z, DeviceMem_Replay.A0_z, simulation->num_detector * record_nz * sizeof(unsigned long long), cudaMemcpyDeviceToHost);

		
		if (simOpt.do_output_A_arr) {
			output_A_rz(simulation, HostMem_Replay.A_rz, simOpt.do_output_bin); // output the absorbance
			output_A0_z(simulation, HostMem_Replay.A0_z, simOpt.do_output_bin);
		}

		

		sumStruc.time3 = clock();
		printf("finish replay, cost %.2f secs\n", (double)(sumStruc.time3 - sumStruc.time2) / CLOCKS_PER_SEC);
		output_sim_summary(simulation, sumStruc, simOpt.do_replay);


		// free the memory
		FreeMemStructs_replay(&HostMem_Replay, &DeviceMem_Replay);
		delete[] temp_SDS_detect_num;
		delete[] replay_reflectance;
		for (int i = 0; i < simulation->num_detector; i++) {
			for (int j = 0; j < total_SDS_detect_num[i]; j++) {
				delete[] pathlength_weight_arr[i][j];
			}
			delete[] pathlength_weight_arr[i];
		}
		delete[] pathlength_weight_arr;
	}

	// free the memory
	FreeMemStructs(&HostMem, &DeviceMem);

	delete[] total_SDS_detect_num;
	delete[] reflectance;
}

void calculate_average_pathlength(double *average_PL ,float ***pathlength_weight_arr, SimulationStruct *sim, int *total_SDS_detect_num)
{
	clock_t time1 = clock(); // tic
	double inverse_start_weight = double(1/sim->start_weight);
	double sum_photon_reflectance = 0;
	double sum_photon_change_reflectnace = 0;
	double photon_energy = 0;
	for (int s = 0; s < sim->num_detector; s++) {
		for (int l = 1; l <= sim->num_layers; l++) {
			sum_photon_reflectance = 0;
			sum_photon_change_reflectnace = 0;
			double changed_mua = mua_change_ratio * sim->layers[l].mua;
			for (int i = 0; i < total_SDS_detect_num[s]; i++) {
				photon_energy = pathlength_weight_arr[s][i][0] * inverse_start_weight;
				sum_photon_reflectance += photon_energy;
				photon_energy *= exp(-1 * changed_mua * pathlength_weight_arr[s][i][l]);
				sum_photon_change_reflectnace += photon_energy;
			}
			average_PL[s * sim->num_layers + l - 1] = log(sum_photon_reflectance / sum_photon_change_reflectnace) / changed_mua;
		}
	}
	clock_t time2 = clock(); // toc
	printf("finish average pathlength, cost %.2f secs\n", (double)(time2 - time1) / CLOCKS_PER_SEC);
}

void calculate_reflectance(Fibers* f, float *result, int* total_SDS_detect_num, vector<vector<curandState>>& detected_state_arr, int num_of_threads)
{
	for (int i = 0; i < num_of_threads; i++)
	{
		// record the weight, count detected photon number, and record pathlength
		for (int k = 0; k < f[i].detected_photon_counter; k++) {
			int s = f[i].detected_SDS_number[k]; // the detecting SDS, start from 1
			result[s - 1] += f[i].data[k];
			total_SDS_detect_num[s - 1]++;
			detected_state_arr[s - 1].push_back(f[i].detected_state[k]);
		}
	}
}

//void calculate_reflectance(Fibers* f, float *result, float (*pathlength_weight_arr)[NUM_LAYER + 1][detected_temp_size], int *total_SDS_detect_num, int *temp_SDS_detect_num)
//SDS_should_be: the detecting SDS, start from s=1 for SDS1
void calculate_reflectance_replay(Fibers_Replay* f_r, float *result, float ***pathlength_weight_arr, int *temp_SDS_detect_num, int *total_SDS_detect_num, int SDS_should_be, int num_layers, int num_of_threads)
{
	for (int i = 0; i < num_of_threads; i++)
	{
		// record the weight, count detected photon number, and record pathlength
		result[SDS_should_be -1] += f_r[i].data;
		pathlength_weight_arr[SDS_should_be - 1][temp_SDS_detect_num[SDS_should_be - 1]][0] = f_r[i].data;
		for (int l = 0; l < num_layers; l++) {
			pathlength_weight_arr[SDS_should_be - 1][temp_SDS_detect_num[SDS_should_be - 1]][l + 1] = f_r[i].layer_pathlength[l];
		}
		pathlength_weight_arr[SDS_should_be - 1][temp_SDS_detect_num[SDS_should_be - 1]][num_layers + 1] = f_r[i].scatter_event;
				
		temp_SDS_detect_num[SDS_should_be - 1]++;
		if (temp_SDS_detect_num[SDS_should_be - 1] >= total_SDS_detect_num[SDS_should_be - 1]) { // if all the photons are replayed, then break
			break;
		}
	}
}

//Device function to add an unsigned integer to an unsigned long long using CUDA Compute Capability 1.1
__device__ void AtomicAddULL(unsigned long long* address, unsigned int add)
{
	if (atomicAdd((unsigned int*)address, add) + add<add)
		atomicAdd(((unsigned int*)address) + 1, 1u);
}

__global__ void MCd(MemStruct DeviceMem, unsigned long long seed, int num_of_threads, int num_of_threads_per_block)
{

	//Block index
	int bx = blockIdx.x;

	//Thread index
	int tx = threadIdx.x;

	//First element processed by the block
	int begin = num_of_threads_per_block * bx;

	float s;	//step length

	unsigned int w_temp;

	PhotonStruct p = DeviceMem.p[begin + tx];
	Fibers f = DeviceMem.f[begin + tx];

	int new_layer;

	curandState state = p.state_run; // get the state of curand from the photon

	//First, make sure the thread (photon) is active
	unsigned int ii = 0;
	if (!DeviceMem.thread_active[begin + tx]) ii = NUMSTEPS_GPU;

	unsigned int index, w, index_old;
	index_old = 0;
	w = 0;

	bool k = true;

	for (; ii<NUMSTEPS_GPU; ii++) //this is the main while loop
	{
		if (layers_dc[p.layer].mutr != FLT_MAX)
			s = -__logf(rn_gen(&state))*layers_dc[p.layer].mutr;//sample step length [cm] //HERE AN OPEN_OPEN FUNCTION WOULD BE APPRECIATED
		else
			s = 100.0f;//temporary, say the step in glass is 100 cm.

		//Check for layer transitions and in case, calculate s
		new_layer = p.layer;
		if (p.z + s*p.dz<layers_dc[p.layer].z_min) {
			new_layer--;
			s = __fdividef(layers_dc[p.layer].z_min - p.z, p.dz);
		} //Check for upwards reflection/transmission & calculate new s
		if (p.z + s*p.dz>layers_dc[p.layer].z_max) {
			new_layer++;
			s = __fdividef(layers_dc[p.layer].z_max - p.z, p.dz);
		} //Check for downward reflection/transmission

		p.x += p.dx*s;
		p.y += p.dy*s;
		p.z += p.dz*s;

		p.scatter_event++;

		if (p.z>layers_dc[p.layer].z_max)p.z = layers_dc[p.layer].z_max;//needed?
		if (p.z<layers_dc[p.layer].z_min)p.z = layers_dc[p.layer].z_min;//needed?

		if (new_layer != p.layer)
		{
			int temp_layer = p.layer;
			// set the remaining step length to 0
			s = 0.0f;

			if (Reflect(&p, new_layer, &state) == 0u)//Check for reflection
			{
				if (new_layer == 0)
				{   //Diffuse reflectance
					bool detected = detect(&p, &f);
					if (detected == 1) {
						AtomicAddULL(&DeviceMem.R[0], p.weight);
						p.weight = 0; // Set the remaining weight to 0, effectively killing the photon
					}
					else { // maybe the detector will reflect the photon
						if (rn_gen(&state) > *detector_reflectance_dc) {
							AtomicAddULL(&DeviceMem.R[0], p.weight);
							p.weight = 0;
						}
						else // reflect into tissue
						{
							p.dz *= -1;
							p.z *= -1;
							p.layer = temp_layer;
						}
					}
				}
				if (new_layer > *n_layers_dc)
				{	//Transmitted
					p.weight = 0; // Set the remaining weight to 0, effectively killing the photon
				}
			}
		}

		if (s > 0.0f)
		{
			// Drop weight (apparently only when the photon is scattered)
			w_temp = __float2uint_rn(layers_dc[p.layer].mua*layers_dc[p.layer].mutr*__uint2float_rn(p.weight));
			//w_temp = layers_dc[p.layer].mua*layers_dc[p.layer].mutr*p.weight;
			p.weight -= w_temp;
			// store the absorbed power to grid
				if (p.first_scatter) {
					unsigned int index;
					index = min(__float2int_rz(__fdividef(p.z, record_dz)), (int)(record_nz - 1));
					AtomicAddULL(&DeviceMem.AA0_z[index], w_temp);
					p.first_scatter = false;
				}
				else {
					index = min(__float2int_rz(__fdividef(p.z, record_dz)), (int)(record_nz - 1)) *record_nr + min(__float2int_rz(__fdividef(sqrtf(p.x*p.x + p.y*p.y), record_dr)), (int)record_nr - 1);

					if (index == index_old)
					{
						w += w_temp;
					}
					else// if(w!=0)
					{
						AtomicAddULL(&DeviceMem.AA_rz[index_old], w);
						index_old = index;
						w = w_temp;
					}
				}

			Spin(&p, layers_dc[p.layer].g, &state);
		}

		if (!PhotonSurvive(&p, &state)) //if the photon doesn't survive
		{
			k = false;
			if (atomicAdd(DeviceMem.num_terminated_photons, 1u) < (*num_photons_dc - num_of_threads))
			{	// Ok to launch another photon
				LaunchPhoton(&p, &state);//Launch a new photon
				state = p.state_run; // reload the state of this thread
			}
			else
			{	// No more photons should be launched. 
				AtomicAddULL(&DeviceMem.AA_rz[index_old], w);
				DeviceMem.thread_active[begin + tx] = 0u; // Set thread to inactive
				ii = NUMSTEPS_GPU;				// Exit main loop
			}
		}

	}//end main for loop!
	if (w != 0)
		AtomicAddULL(&DeviceMem.AA_rz[index_old], w);


	p.state_run = state; // store the current curand state into the photon

	//// truly need?
	//if (k == true && DeviceMem.thread_active[begin + tx] == 1u)    // photons are not killed after numerous steps
	//{
	//	if (*DeviceMem.num_terminated_photons >= (*num_photons_dc - NUM_THREADS))
	//		DeviceMem.thread_active[begin + tx] = 0u;
	//}

	__syncthreads();//necessary?

	//save the state of the MC simulation in global memory before exiting
	DeviceMem.p[begin + tx] = p;	//This one is incoherent!!!
	DeviceMem.f[begin + tx] = f;

}//end MCd

__global__ void MCd_replay(MemStruct DeviceMem, MemStruct_Replay DeviceMem_Replay, int detected_SDS, int num_of_threads_per_block)
{
	//Block index
	int bx = blockIdx.x;
	//Thread index
	int tx = threadIdx.x;
	//First element processed by the block
	int begin = num_of_threads_per_block * bx;

	//First, make sure the thread (photon) is active
	if (DeviceMem.thread_active[begin + tx]) {
		float s;	//step length

		unsigned int index, w, index_old;
		index_old = 0;
		w = 0;

		unsigned int w_temp;

		PhotonStruct p = DeviceMem.p[begin + tx];
		Fibers f = DeviceMem.f[begin + tx];
		Fibers_Replay f_r = DeviceMem_Replay.f_r[begin + tx];

		// load the seed of detected photon and launch it
		curandState state = DeviceMem.state[begin + tx];
		LaunchPhoton(&p, &state);

		state = p.state_run; // get the state of curand from the photon

		int new_layer;

		bool k = true;

		while (true) //this is the main while loop
		{
			if (layers_dc[p.layer].mutr != FLT_MAX)
				s = -__logf(rn_gen(&state))*layers_dc[p.layer].mutr;//sample step length [cm] //HERE AN OPEN_OPEN FUNCTION WOULD BE APPRECIATED
			else
				s = 100.0f;//temporary, say the step in glass is 100 cm.

			//Check for layer transitions and in case, calculate s
			new_layer = p.layer;
			if (p.z + s*p.dz < layers_dc[p.layer].z_min) {
				new_layer--;
				s = __fdividef(layers_dc[p.layer].z_min - p.z, p.dz);
			} //Check for upwards reflection/transmission & calculate new s
			if (p.z + s*p.dz > layers_dc[p.layer].z_max) {
				new_layer++;
				s = __fdividef(layers_dc[p.layer].z_max - p.z, p.dz);
			} //Check for downward reflection/transmission

			p.x += p.dx*s;
			p.y += p.dy*s;
			p.z += p.dz*s;

			f_r.scatter_event++;
			f_r.layer_pathlength[p.layer - 1] += s;

			if (p.z > layers_dc[p.layer].z_max)p.z = layers_dc[p.layer].z_max;//needed?
			if (p.z < layers_dc[p.layer].z_min)p.z = layers_dc[p.layer].z_min;//needed?

			if (new_layer != p.layer)
			{
				int temp_layer = p.layer;
				// set the remaining step length to 0
				s = 0.0f;

				if (Reflect(&p, new_layer, &state) == 0u)//Check for reflection
				{
					if (new_layer == 0)
					{ //Diffuse reflectance
						bool detected = detect_replay(&p, &f, detected_SDS);
						if (detected) { // store the photon information into f_r
							f_r.have_detected = true;
							f_r.data = f.data[0];
							f_r.detected_SDS_number = f.detected_SDS_number[0];
							p.weight = 0; // Set the remaining weight to 0, effectively killing the photon
							break;
						}
						else { // maybe the detector will reflect the photon
							if (rn_gen(&state) > *detector_reflectance_dc) {
								f_r.have_detected = true;
								f_r.data = f.data[0];
								f_r.detected_SDS_number = f.detected_SDS_number[0];
								p.weight = 0;
								break;
							}
							else
							{
								p.dz *= -1;
								p.z *= -1;
								p.layer = temp_layer;
							}
						}
					}
					if (new_layer > *n_layers_dc)
					{	//Transmitted
						p.weight = 0; // Set the remaining weight to 0, effectively killing the photon
						break;
					}
				}
			}

			if (s > 0.0f)
			{
				// Drop weight (apparently only when the photon is scattered)
				w_temp = __float2uint_rn(layers_dc[p.layer].mua*layers_dc[p.layer].mutr*__uint2float_rn(p.weight));
				//w_temp = layers_dc[p.layer].mua*layers_dc[p.layer].mutr*p.weight;
				p.weight -= w_temp;

				// store the absorbed power to grid
				if (p.first_scatter) {
					unsigned int index;
					index = detected_SDS*record_nz + min(__float2int_rz(__fdividef(p.z, record_dz)), (int)(record_nz - 1));
					AtomicAddULL(&DeviceMem_Replay.A0_z[index], w_temp);
					p.first_scatter = false;
				}
				else {
					index = detected_SDS*record_nr*record_nz + min(__float2int_rz(__fdividef(p.z, record_dz)), (int)(record_nz - 1)) *record_nr + min(__float2int_rz(__fdividef(sqrtf(p.x*p.x + p.y*p.y), record_dr)), (int)record_nr - 1);

					if (index == index_old)
					{
						w += w_temp;
					}
					else// if(w!=0)
					{
						AtomicAddULL(&DeviceMem_Replay.A_rz[index_old], w);
						index_old = index;
						w = w_temp;
					}
				}

				Spin(&p, layers_dc[p.layer].g, &state);
			}

			if (!PhotonSurvive(&p, &state)) //if the photon doesn't survive
			{
				break;
			}

		}//end main for loop!

		if (w != 0)
			AtomicAddULL(&DeviceMem_Replay.A_rz[index_old], w);
		p.state_run = state; // store the current rand state

		//save the state of the MC simulation in global memory before exiting
		DeviceMem.p[begin + tx] = p;	//This one is incoherent!!!
		DeviceMem.f[begin + tx] = f;
		DeviceMem_Replay.f_r[begin + tx] = f_r;
	}
}//end MCd

__device__ void LaunchPhoton(PhotonStruct* p, curandState *state)
{
	p->state_seed = *state; // store the init curandState of photon
	/*
	float rnd_position, rnd_Azimuth, rnd_direction, rnd_rotated;
	float AzimuthAngle;
	float launchPosition;
	float theta_direction;
	float rotated_angle;
	float uxprime, uyprime, uzprime;
	float angle = -ANGLE * PI / 180;
	*/


	//rnd_position = rn_gen(state);
	//rnd_Azimuth = rn_gen(state);
	//rnd_direction = rn_gen(state);
	//rnd_rotated = rn_gen(state);
	//AzimuthAngle = 2 * PI * rnd_Azimuth;
	//rotated_angle = 2 * PI * rnd_rotated; //YU-modified // modified to point source

	//float beam_width = 0.0175;  // 175 um, Gaussian beam profile
	//float beam_width = illumination_r;

	// infinite narrow beam for impulse response


	//theta_direction = asin(NAOfSource / n_source)*rnd_direction;
	//p->dz = cos(theta_direction);
	//p->dx = sin(theta_direction) * cos(rotated_angle);
	//p->dy = sin(theta_direction) * sin(rotated_angle);

	//uxprime = cos(angle)*p->dx - sin(angle)*p->dz;
	//uyprime = sin(theta_direction)*sin(rotated_angle);
	//uzprime = sin(angle)*p->dx + cos(angle)*p->dz; // YU-modified

	//p->dx = uxprime, p->dy = uyprime, p->dz = uzprime;

	if (*source_probe_oblique_dc)
	{
		p->x = 0.0;
		p->y = 0.0;
		p->z = 0.0;

		// the angle is toward positive x-axis
		p->dx = 1.0*sin(detInfo_dc[0].angle);
		p->dy = 0.0;
		p->dz = 1.0*cos(detInfo_dc[0].angle);
	}
	else // if source_probe_oblique_dc == false
	{
		if (detInfo_dc[0].raduis == 0) { // for point source
			p->x = 0.0;
			p->y = 0.0;
			p->z = 0.0;
		}
		else {
			float rnd_position, rnd_Azimuth;
			float launchPosition;
			float AzimuthAngle;

			rnd_position = rn_gen(state);
			rnd_Azimuth = rn_gen(state);
			launchPosition = detInfo_dc[0].raduis*rnd_position;
			AzimuthAngle = 2 * PI * rnd_Azimuth;
			p->x = launchPosition*sin(AzimuthAngle);
			p->y = launchPosition*cos(AzimuthAngle);
			p->z = 0;
		}
		if (detInfo_dc[0].NA == 0) { // for pencil beam
			p->dx = 0.0, p->dy = 0.0, p->dz = 1.0;
		}
		else { // for NA source
			float rnd_direction, rnd_rotated;
			float theta_direction; // direction angle from +z
			float rotated_angle; // the rotate of direction

			rnd_direction = rn_gen(state);
			rnd_rotated = rn_gen(state);
			theta_direction = asin(detInfo_dc[0].NA / layers_dc[0].n)*rnd_direction;
			rotated_angle = 2 * PI * rnd_rotated;

			p->dz = cos(theta_direction);
			p->dx = sin(theta_direction) * cos(rotated_angle);
			p->dy = sin(theta_direction) * sin(rotated_angle);
		}
	}

	p->layer = 1;
	p->first_scatter = true;

	p->scatter_event = 0;
	
	p->weight = *start_weight_dc; //specular reflection!
	p->state_run = *state; // store the current state of photon after serveral rand
}


__global__ void LaunchPhoton_Global(MemStruct DeviceMem, unsigned long long seed, int num_of_threads_per_block)
{
	int bx = blockIdx.x;
	int tx = threadIdx.x;

	//First element processed by the block
	int begin = num_of_threads_per_block*bx;

	PhotonStruct p;

	curandState state = DeviceMem.state[begin + tx];
	curand_init(seed, begin+tx, 0, &state); // init curandState for each photon

	LaunchPhoton(&p, &state);

	//__syncthreads();//necessary?
	DeviceMem.p[begin + tx] = p;//incoherent!?
}


__device__ void Spin(PhotonStruct* p, float g, curandState *state)
{
	float theta, cost, sint; // cosine and sine of the polar deflection angle theta. 
	float cosp, sinp; // cosine and sine of the azimuthal angle psi. 
	float temp;

	if (g == 0.0f)
	{
		cost = 2.0f*rn_gen(state) - 1.0f;
	}
	else // This is more efficient for g!=0 but of course less efficient for g==0
	{
		// The Henyey-Greenstein phase function
		temp = __fdividef((1.0f - (g)*(g)), (1.0f - (g)+2.0f*(g)*rn_gen(state)));
		cost = __fdividef((1.0f + (g)*(g)-temp*temp), (2.0f*(g)));
	}

	sint = sqrtf(1.0f - cost*cost);

	__sincosf(2.0f*PI*rn_gen(state), &sinp, &cosp); // spin psi [0-2*PI)

	temp = sqrtf(1.0f - p->dz*p->dz);

	if (temp == 0.0f) //normal incident.
	{
		p->dx = sint*cosp;
		p->dy = sint*sinp;
		p->dz = copysignf(cost, p->dz*cost);
	}
	else // regular incident.
	{
		float cxp, cyp;
		cxp = __fdividef(sint*(p->dx*p->dz*cosp - p->dy*sinp), temp) + p->dx*cost;
		cyp = __fdividef(sint*(p->dy*p->dz*cosp + p->dx*sinp), temp) + p->dy*cost;
		p->dx = cxp;
		p->dy = cyp;
		p->dz = -sint*cosp*temp + p->dz*cost;
	}

	//normalisation seems to be required as we are using floats! Otherwise the small numerical error will accumulate
	temp = rsqrtf(p->dx*p->dx + p->dy*p->dy + p->dz*p->dz);
	p->dx = p->dx*temp;
	p->dy = p->dy*temp;
	p->dz = p->dz*temp;
}// end Spin



__device__ unsigned int Reflect(PhotonStruct* p, int new_layer, curandState *state)
{
	//Calculates whether the photon is reflected (returns 1) or not (returns 0)
	// Reflect() will also update the current photon layer (after transmission) and photon direction (both transmission and reflection)

	float n1 = layers_dc[p->layer].n;
	float n2 = layers_dc[new_layer].n;
	float r;
	float cos_angle_i = fabsf(p->dz);

	if (n1 == n2)//refraction index matching automatic transmission and no direction change
	{
		p->layer = new_layer;
		return 0u;
	}

	if (n1>n2 && n2*n2<n1*n1*(1 - cos_angle_i*cos_angle_i))//total internal reflection, no layer change but z-direction mirroring
	{
		p->dz *= -1.0f;
		return 1u;
	}

	if (cos_angle_i == 1.0f)//normal incident
	{
		r = __fdividef((n1 - n2), (n1 + n2));
		if (rn_gen(state) <= r*r)
		{
			//reflection, no layer change but z-direction mirroring
			p->dz *= -1.0f;
			return 1u;
		}
		else
		{	//transmission, no direction change but layer change
			p->layer = new_layer;
			return 0u;
		}
	}

	//gives almost exactly the same results as the old MCML way of doing the calculation but does it slightly faster
	// save a few multiplications, calculate cos_angle_i^2;
	float e = __fdividef(n1*n1, n2*n2)*(1.0f - cos_angle_i*cos_angle_i); //e is the sin square of the transmission angle
	r = 2 * sqrtf((1.0f - cos_angle_i*cos_angle_i)*(1.0f - e)*e*cos_angle_i*cos_angle_i);//use r as a temporary variable
	e = e + (cos_angle_i*cos_angle_i)*(1.0f - 2.0f*e);//Update the value of e
	r = e*__fdividef((1.0f - e - r), ((1.0f - e + r)*(e + r)));//Calculate r	

	if (rn_gen(state) <= r)
	{
		// Reflection, mirror z-direction!
		p->dz *= -1.0f;
		return 1u;
	}
	else
	{
		// Transmission, update layer and direction
		r = __fdividef(n1, n2);
		e = r*r*(1.0f - cos_angle_i*cos_angle_i); //e is the sin square of the transmission angle
		p->dx *= r;
		p->dy *= r;
		p->dz = copysignf(sqrtf(1 - e), p->dz);
		p->layer = new_layer;
		return 0u;
	}

}

__device__ unsigned int PhotonSurvive(PhotonStruct* p, curandState *state)
{
	//Calculate wether the photon survives (returns 1) or dies (returns 0)
	if (p->scatter_event >= max_scatter_time) return 0; // scatter too many times, terminate the photon

	if (p->weight>WEIGHTI) return 1u; // No roulette needed
	if (p->weight == 0u) return 0u;	// Photon has exited slab, i.e. kill the photon

	if (rn_gen(state) < CHANCE)
	{
		p->weight = __float2uint_rn(__fdividef((float)p->weight, CHANCE));
		//p->weight = __fdividef((float)p->weight,CHANCE);
		return 1u;
	}
	return 0u;
}

__device__ bool detect(PhotonStruct* p, Fibers* f)
{
	bool detected_flag = false;

	if (*detector_probe_oblique_dc)
	{
		for (int i = 1; i <= *num_detector_dc; i++)
		{
			// check if the photon is in the range of detector
			// because the detector is oblique, so the detection area is oval
			// use fober detector rathter than ring detector, and each detector locate at (x,y) = (pos,0)
			//if ((pow((p->x - detInfo_dc[i].position)*cos(detInfo_dc[i].angle), 2) + pow(p->y, 2)) <= pow(detInfo_dc[i].raduis, 2))
			if (((p->x - detInfo_dc[i].position)*cos(detInfo_dc[i].angle)*(p->x - detInfo_dc[i].position)*cos(detInfo_dc[i].angle))+((p->y)*(p->y)) <= detInfo_dc[i].raduis*detInfo_dc[i].raduis )
			{
				// let the detector point to the -x direction
				float uz_rotated = (p->dx*sin(detInfo_dc[i].angle)) + fabs(p->dz*cos(detInfo_dc[i].angle));
				float uz_angle = acos(fabs(uz_rotated));
				if (uz_angle <= critical_angle_dc[i]) // in the range of detector NA
				{
					if (f->detected_photon_counter < SDS_detected_temp_size) {
						f->detected_SDS_number[f->detected_photon_counter] = i;
						f->data[f->detected_photon_counter] = p->weight;
						f->detected_state[f->detected_photon_counter] = p->state_seed;
						f->detected_photon_counter++;
					}
					detected_flag = true;
				}
			}

		}
	}
	else // detector_probe_oblique_dc == false
	{
		float uz_angle = acos(fabs(p->dz)); //YU-modified
		float distance;

		distance = sqrt(p->x * p->x + p->y * p->y);

		for (int i = 1; i <= *num_detector_dc; i++)
		{
			if (uz_angle <= critical_angle_dc[i]) { // successfully detected
				if ((distance >= (detInfo_dc[i].position - detInfo_dc[i].raduis)) && (distance <= (detInfo_dc[i].position + detInfo_dc[i].raduis))) {
					// calculate the weight detected by ring detector into a fiber detector
					float temp;
					temp = (distance*distance + detInfo_dc[i].position * detInfo_dc[i].position - detInfo_dc[i].raduis * detInfo_dc[i].raduis) / (2 * distance * detInfo_dc[i].position);
					// check for rounding error!
					if (temp > 1.0f)
						temp = 1.0f;

					if (f->detected_photon_counter < SDS_detected_temp_size) {
						f->detected_SDS_number[f->detected_photon_counter] = i;
						f->data[f->detected_photon_counter] = p->weight * acos(temp) * RPI;
						f->detected_state[f->detected_photon_counter] = p->state_seed;
						f->detected_photon_counter++;
					}
					detected_flag = true;
				}
			}
		}
	}

	if (detected_flag) {
		return true;
	}
	else {
		return false;
	}
}

// detected_SDS start from 0
__device__ bool detect_replay(PhotonStruct* p, Fibers* f, int detected_SDS)
{
	int i = detected_SDS + 1;
	bool detected_flag = false;

	if (*detector_probe_oblique_dc)
	{
		// check if the photon is in the range of detector
		// because the detector is oblique, so the detection area is oval
		// use fober detector rathter than ring detector, and each detector locate at (x,y) = (pos,0)
		//if ((pow((p->x - detInfo_dc[i].position)*cos(detInfo_dc[i].angle), 2) + pow(p->y, 2)) <= pow(detInfo_dc[i].raduis, 2))
		if (((p->x - detInfo_dc[i].position)*cos(detInfo_dc[i].angle)*(p->x - detInfo_dc[i].position)*cos(detInfo_dc[i].angle))+((p->y)*(p->y)) <= detInfo_dc[i].raduis*detInfo_dc[i].raduis )
		{
			// let the detector point to the -x direction
			float uz_rotated = (p->dx*sin(detInfo_dc[i].angle)) + fabs(p->dz*cos(detInfo_dc[i].angle));
			float uz_angle = acos(fabs(uz_rotated));
			if (uz_angle <= critical_angle_dc[i]) // in the range of detector NA
			{
				if (f->detected_photon_counter < SDS_detected_temp_size) {
					f->detected_SDS_number[f->detected_photon_counter] = i;
					f->data[f->detected_photon_counter] = p->weight;
					f->detected_state[f->detected_photon_counter] = p->state_seed;
					f->detected_photon_counter++;
				}
				detected_flag = true;
			}
		}
	}
	else
	{
		float uz_angle = acos(fabs(p->dz));
		float distance;

		distance = sqrt(p->x * p->x + p->y * p->y);

		if (uz_angle <= critical_angle_dc[i]) { // successfully detected
			if ((distance >= (detInfo_dc[i].position - detInfo_dc[i].raduis)) && (distance <= (detInfo_dc[i].position + detInfo_dc[i].raduis))) {
				float temp;
				temp = (distance*distance + detInfo_dc[i].position * detInfo_dc[i].position - detInfo_dc[i].raduis * detInfo_dc[i].raduis) / (2 * distance * detInfo_dc[i].position);
				// check for rounding error!
				if (temp > 1.0f)
					temp = 1.0f;

				if (f->detected_photon_counter < SDS_detected_temp_size) {
					f->detected_SDS_number[f->detected_photon_counter] = i;
					f->data[f->detected_photon_counter] = p->weight  * acos(temp) * RPI;
					f->detected_state[f->detected_photon_counter] = p->state_seed;
					f->detected_photon_counter++;
				}
				detected_flag = true;
			}
		}
	}

	if (detected_flag) {
		return true;
	}
	else {
		return false;
	}
}

int InitDCMem(SimulationStruct* sim)
{
	// Copy n_layers_dc to constant device memory
	cudaMemcpyToSymbol(n_layers_dc, &(sim->num_layers), sizeof(unsigned int));

	// Copy num_detector_dc to constant device memory
	cudaMemcpyToSymbol(num_detector_dc, &(sim->num_detector), sizeof(unsigned int));

	// Copy start_weight_dc to constant device memory
	cudaMemcpyToSymbol(start_weight_dc, &(sim->start_weight), sizeof(float));

	// Copy layer data to constant device memory
	cudaMemcpyToSymbol(layers_dc, sim->layers, (sim->num_layers + 2) * sizeof(LayerStruct));

	// Copy detector data to constant device memory
	cudaMemcpyToSymbol(detInfo_dc, sim->detInfo, (sim->num_detector + 1) * sizeof(DetectorInfoStruct));

	// Copy num_photons_dc to constant device memory
	cudaMemcpyToSymbol(num_photons_dc, &(sim->number_of_photons), sizeof(unsigned long long));
	
	// Copy detector_reflectance_dc to constant device memory
	cudaMemcpyToSymbol(detector_reflectance_dc, &(sim->detector_reflectance), sizeof(float));

	// Copy detector critical angles to constant device memory
	cudaMemcpyToSymbol(critical_angle_dc, sim->critical_arr, (sim->num_detector + 1) * sizeof(float));
	
	// Copy source probe oblique to constant device memory
	cudaMemcpyToSymbol(source_probe_oblique_dc, &(sim->source_probe_oblique), sizeof(bool));
	
	// Copy detector probe oblique to constant device memory
	cudaMemcpyToSymbol(detector_probe_oblique_dc, &(sim->detector_probe_oblique), sizeof(bool));

	return 0;
}

int InitMemStructs(MemStruct* HostMem, MemStruct* DeviceMem, SimulationStruct* sim, int num_of_threads)
{
	// Allocate p on the device!!
	cudaMalloc((void**)&DeviceMem->p, num_of_threads * sizeof(PhotonStruct));

	// Allocate thread_active on the device and host
	HostMem->thread_active = (unsigned int*)malloc(num_of_threads * sizeof(unsigned int));
	if (HostMem->thread_active == NULL) { printf("Error allocating HostMem->thread_active"); exit(1); }
	for (int i = 0; i<num_of_threads; i++)HostMem->thread_active[i] = 1u;

	cudaMalloc((void**)&DeviceMem->thread_active, num_of_threads * sizeof(unsigned int));
	cudaMemcpy(DeviceMem->thread_active, HostMem->thread_active, num_of_threads * sizeof(unsigned int), cudaMemcpyHostToDevice);

	//Allocate num_launched_photons on the device and host
	HostMem->num_terminated_photons = (unsigned long long*) malloc(sizeof(unsigned long long));
	if (HostMem->num_terminated_photons == NULL) { printf("Error allocating HostMem->num_terminated_photons"); exit(1); }
	*HostMem->num_terminated_photons = 0;

	cudaMalloc((void**)&DeviceMem->num_terminated_photons, sizeof(unsigned long long));
	cudaMemcpy(DeviceMem->num_terminated_photons, HostMem->num_terminated_photons, sizeof(unsigned long long), cudaMemcpyHostToDevice);

	//Allocate and initialize fiber f on the device and host
	HostMem->f = (Fibers*)malloc(num_of_threads * sizeof(Fibers));
	cudaMalloc((void**)&DeviceMem->f, num_of_threads * sizeof(Fibers));

	fiber_initialization(HostMem->f, num_of_threads); //Wang modified
	cudaMemcpy(DeviceMem->f, HostMem->f, num_of_threads * sizeof(Fibers), cudaMemcpyHostToDevice);

	// Allocate R on host and device
	HostMem->R = (unsigned long long*) malloc(sizeof(unsigned long long));
	if (HostMem->R == NULL) { printf("Error allocating HostMem->R"); exit(1);}
	cudaMalloc((void**)&DeviceMem->R, sizeof(unsigned long long));
	cudaMemset(DeviceMem->R, 0,sizeof(unsigned long long));


	int rz_size, z0_size;
	rz_size = record_nr*record_nz;
	z0_size = record_nz;

	// Allocate AA_rz on host and device
	HostMem->AA_rz = (unsigned long long*) malloc(rz_size * sizeof(unsigned long long));
	if (HostMem->AA_rz == NULL) { printf("Error allocating HostMem->AA_rz"); exit(1); }
	cudaMalloc((void**)&DeviceMem->AA_rz, rz_size * sizeof(unsigned long long));
	cudaMemset(DeviceMem->AA_rz, 0, rz_size * sizeof(unsigned long long));

	// Allocate AA0_z on host and device
	HostMem->AA0_z = (unsigned long long*) malloc(z0_size * sizeof(unsigned long long));
	if (HostMem->AA0_z == NULL) { printf("Error allocating HostMem->AA_rz"); exit(1); }
	cudaMalloc((void**)&DeviceMem->AA0_z, z0_size * sizeof(unsigned long long));
	cudaMemset(DeviceMem->AA0_z, 0, z0_size * sizeof(unsigned long long));


	//Allocate states on the device and host
	HostMem->state = (curandState*)malloc(num_of_threads * sizeof(curandState));
	cudaMalloc((void**)&DeviceMem->state, num_of_threads * sizeof(curandState));

	return 1;
}

int InitMemStructs_replay(MemStruct_Replay* HostMem, MemStruct_Replay* DeviceMem, SimulationStruct* sim, int num_of_threads)
{
	//Allocate and initialize fiber_Replay f_r on the device and host
	HostMem->f_r = (Fibers_Replay*)malloc(num_of_threads * sizeof(Fibers_Replay));
	cudaMalloc((void**)&DeviceMem->f_r, num_of_threads * sizeof(Fibers_Replay));
	fiber_initialization_replay(HostMem->f_r, sim, num_of_threads);
	cudaMemcpy(DeviceMem->f_r, HostMem->f_r, num_of_threads * sizeof(Fibers_Replay), cudaMemcpyHostToDevice);

	int rz_size, z0_size;
	rz_size = sim->num_detector*record_nr*record_nz;
	z0_size = sim->num_detector*record_nz;

	// Allocate A_rz on host and device
	HostMem->A_rz = (unsigned long long*) malloc(rz_size * sizeof(unsigned long long));
	if (HostMem->A_rz == NULL) { printf("Error allocating HostMem->A_rz"); exit(1); }
	cudaMalloc((void**)&DeviceMem->A_rz, rz_size * sizeof(unsigned long long));
	cudaMemset(DeviceMem->A_rz, 0, rz_size * sizeof(unsigned long long));

	// Allocate A0_z on host and device
	HostMem->A0_z = (unsigned long long*) malloc(z0_size * sizeof(unsigned long long));
	if (HostMem->A0_z == NULL) { printf("Error allocating HostMem->A_rz"); exit(1); }
	cudaMalloc((void**)&DeviceMem->A0_z, z0_size * sizeof(unsigned long long));
	cudaMemset(DeviceMem->A0_z, 0, z0_size * sizeof(unsigned long long));



	return 1;
}

void FreeMemStructs(MemStruct* HostMem, MemStruct* DeviceMem)
{
	free(HostMem->thread_active);
	free(HostMem->num_terminated_photons);
	free(HostMem->f);
	free(HostMem->state);
	free(HostMem->AA_rz);
	free(HostMem->AA0_z);
	free(HostMem->R);

	cudaFree(DeviceMem->thread_active);
	cudaFree(DeviceMem->num_terminated_photons);
	cudaFree(DeviceMem->f);
	cudaFree(DeviceMem->state);
	cudaFree(DeviceMem->AA_rz);
	cudaFree(DeviceMem->AA0_z);
	cudaFree(DeviceMem->R);

}

void FreeMemStructs_replay(MemStruct_Replay* HostMem, MemStruct_Replay* DeviceMem)
{
	free(HostMem->f_r);
	free(HostMem->A_rz);
	free(HostMem->A0_z);
	
	cudaFree(DeviceMem->f_r);
	cudaFree(DeviceMem->A_rz);
	cudaFree(DeviceMem->A0_z);
	


}

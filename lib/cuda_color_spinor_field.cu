#include <stdlib.h>
#include <stdio.h>
#include <typeinfo>

#include <color_spinor_field.h>
#include <blas_quda.h>

#include <string.h>
#include <iostream>
#include <misc_helpers.h>
#include <face_quda.h>
#include <dslash_quda.h>

#ifdef DEVICE_PACK
#define REORDER_LOCATION QUDA_CUDA_FIELD_LOCATION
#else
#define REORDER_LOCATION QUDA_CPU_FIELD_LOCATION
#endif

namespace quda {

  int cudaColorSpinorField::initGhostFaceBuffer = 0;
  void* cudaColorSpinorField::ghostFaceBuffer; //gpu memory
  void* cudaColorSpinorField::fwdGhostFaceBuffer[QUDA_MAX_DIM]; //pointers to ghostFaceBuffer
  void* cudaColorSpinorField::backGhostFaceBuffer[QUDA_MAX_DIM]; //pointers to ghostFaceBuffer
  QudaPrecision cudaColorSpinorField::facePrecision; 

  /*cudaColorSpinorField::cudaColorSpinorField() : 
    ColorSpinorField(), v(0), norm(0), alloc(false), init(false) {

    }*/

  cudaColorSpinorField::cudaColorSpinorField(const ColorSpinorParam &param) : 
    ColorSpinorField(param), alloc(false), init(true), texInit(false){

    // this must come before create
    if (param.create == QUDA_REFERENCE_FIELD_CREATE) {
      v = param.v;
      norm = param.norm;
    }

    create(param.create);

    if  (param.create == QUDA_NULL_FIELD_CREATE) {
      // do nothing
    } else if (param.create == QUDA_ZERO_FIELD_CREATE) {
      zero();
    } else if (param.create == QUDA_REFERENCE_FIELD_CREATE) {
      // dp nothing
    } else if (param.create == QUDA_COPY_FIELD_CREATE){
      errorQuda("not implemented");
    }
    checkCudaError();
  }

  cudaColorSpinorField::cudaColorSpinorField(const cudaColorSpinorField &src) : 
    ColorSpinorField(src), alloc(false), init(true), texInit(false){
    create(QUDA_COPY_FIELD_CREATE);
    copySpinorField(src);
  }

  // creates a copy of src, any differences defined in param
  cudaColorSpinorField::cudaColorSpinorField(const ColorSpinorField &src, 
					     const ColorSpinorParam &param) :
    ColorSpinorField(src), alloc(false), init(true), texInit(false){  
    // can only overide if we are not using a reference or parity special case
    if (param.create != QUDA_REFERENCE_FIELD_CREATE || 
	(param.create == QUDA_REFERENCE_FIELD_CREATE && 
	 src.SiteSubset() == QUDA_FULL_SITE_SUBSET && 
	 param.siteSubset == QUDA_PARITY_SITE_SUBSET && 
	 typeid(src) == typeid(cudaColorSpinorField) ) || 
         (param.create == QUDA_REFERENCE_FIELD_CREATE && param.eigv_dim > 0)) {
      reset(param);//looks ok for eigenvector subset...
    } else {
      errorQuda("Undefined behaviour"); // else silent bug possible?
    }
    // This must be set before create is called
    if (param.create == QUDA_REFERENCE_FIELD_CREATE) {
      if (typeid(src) == typeid(cudaColorSpinorField)) {
	v = (void*)src.V();
	norm = (void*)src.Norm();
      } else {
	errorQuda("Cannot reference a non-cuda field");
      }

      if (this->EigvDim() > 0) 
      {//setup eigenvector form the set
         if(eigv_dim != this->EigvDim()) errorQuda("\nEigenvector set does not match..\n") ;//for debug only.
         if(eigv_id > -1)
         {
           printfQuda("\nSetting pointers for vector id %d\n", eigv_id); //for debug only.
           v    = (void*)((char*)v + eigv_id*bytes);         
           norm = (void*)((char*)norm + eigv_id*norm_bytes);         
         }
       //do nothing for the eigenvector subset...
      }
    }

    create(param.create);


    if (param.create == QUDA_NULL_FIELD_CREATE) {
      // do nothing
    } else if (param.create == QUDA_ZERO_FIELD_CREATE) {
      zero();
    } else if (param.create == QUDA_COPY_FIELD_CREATE) {
      copySpinorField(src);
    } else if (param.create == QUDA_REFERENCE_FIELD_CREATE) {
      // do nothing
    } else {
      errorQuda("CreateType %d not implemented", param.create);
    }

    clearGhostPointers();//?
  }

  cudaColorSpinorField::cudaColorSpinorField(const ColorSpinorField &src) 
    : ColorSpinorField(src), alloc(false), init(true), texInit(false){
    create(QUDA_COPY_FIELD_CREATE);
    copySpinorField(src);
    clearGhostPointers();
  }

  ColorSpinorField& cudaColorSpinorField::operator=(const ColorSpinorField &src) {
    if (typeid(src) == typeid(cudaColorSpinorField)) {
      *this = (dynamic_cast<const cudaColorSpinorField&>(src));
    } else if (typeid(src) == typeid(cpuColorSpinorField)) {
      *this = (dynamic_cast<const cpuColorSpinorField&>(src));
    } else {
      errorQuda("Unknown input ColorSpinorField %s", typeid(src).name());
    }
    return *this;
  }

  cudaColorSpinorField& cudaColorSpinorField::operator=(const cudaColorSpinorField &src) {
    if (&src != this) {
      // keep current attributes unless unset
      if (!ColorSpinorField::init) { // note this will turn a reference field into a regular field
	destroy();
	ColorSpinorField::operator=(src);
	create(QUDA_COPY_FIELD_CREATE);
      }
      copySpinorField(src);
    }
    return *this;
  }

  cudaColorSpinorField& cudaColorSpinorField::operator=(const cpuColorSpinorField &src) {
    // keep current attributes unless unset
    if (!ColorSpinorField::init) { // note this will turn a reference field into a regular field
      destroy();
      ColorSpinorField::operator=(src);
      create(QUDA_COPY_FIELD_CREATE);
    }
    loadSpinorField(src);
    return *this;
  }

  cudaColorSpinorField::~cudaColorSpinorField() {
    destroy();
  }

  bool cudaColorSpinorField::isNative() const {

    if (precision == QUDA_DOUBLE_PRECISION) {
      if (fieldOrder == QUDA_FLOAT2_FIELD_ORDER) return true;
    } else if (precision == QUDA_SINGLE_PRECISION) {
      if (nSpin == 4) {
	if (fieldOrder == QUDA_FLOAT4_FIELD_ORDER) return true;
      } else if (nSpin == 1) {
	if (fieldOrder == QUDA_FLOAT2_FIELD_ORDER) return true;
      }
    } else if (precision == QUDA_HALF_PRECISION) {
      if (nSpin == 4) {
	if (fieldOrder == QUDA_FLOAT4_FIELD_ORDER) return true;
      } else if (nSpin == 1) {
	if (fieldOrder == QUDA_FLOAT2_FIELD_ORDER) return true;
      }
    }

    return false;
  }

  void cudaColorSpinorField::create(const QudaFieldCreate create) {

    if (siteSubset == QUDA_FULL_SITE_SUBSET && siteOrder != QUDA_EVEN_ODD_SITE_ORDER) {
      errorQuda("Subset not implemented");
    }

    //FIXME: This addition is temporary to ensure we have the correct
    //field order for a given precision
    //if (precision == QUDA_DOUBLE_PRECISION) fieldOrder = QUDA_FLOAT2_FIELD_ORDER;
    //else fieldOrder = (nSpin == 4) ? QUDA_FLOAT4_FIELD_ORDER : QUDA_FLOAT2_FIELD_ORDER;

    if (create != QUDA_REFERENCE_FIELD_CREATE) {
      v = device_malloc(bytes);
      if (precision == QUDA_HALF_PRECISION) {
	norm = device_malloc(norm_bytes);
      }
      alloc = true;
    }

    if (siteSubset == QUDA_FULL_SITE_SUBSET) {
      if(eigv_dim != 0) errorQuda("Eigenvectors must be parity fields!");
      // create the associated even and odd subsets
      ColorSpinorParam param;
      param.siteSubset = QUDA_PARITY_SITE_SUBSET;
      param.nDim = nDim;
      memcpy(param.x, x, nDim*sizeof(int));
      param.x[0] /= 2; // set single parity dimensions
      param.create = QUDA_REFERENCE_FIELD_CREATE;
      param.v = v;
      param.norm = norm;
      even = new cudaColorSpinorField(*this, param);
      odd = new cudaColorSpinorField(*this, param);

      // need this hackery for the moment (need to locate the odd pointer half way into the full field)
      (dynamic_cast<cudaColorSpinorField*>(odd))->v = (void*)((char*)v + bytes/2);
      if (precision == QUDA_HALF_PRECISION) 
	(dynamic_cast<cudaColorSpinorField*>(odd))->norm = (void*)((char*)norm + norm_bytes/2);

#ifdef USE_TEXTURE_OBJECTS
      dynamic_cast<cudaColorSpinorField*>(even)->destroyTexObject();
      dynamic_cast<cudaColorSpinorField*>(even)->createTexObject();
      dynamic_cast<cudaColorSpinorField*>(odd)->destroyTexObject();
      dynamic_cast<cudaColorSpinorField*>(odd)->createTexObject();
#endif
    }
    else{//siteSubset == QUDA_PARITY_SITE_SUBSET

      //! setup an object for selected eigenvector (the 1st one as a default):
      if ((eigv_dim > 0) && (create != QUDA_REFERENCE_FIELD_CREATE) && (eigv_id == -1)) 
      {
         if(bytes > 1811939328) warningQuda("\nCUDA API probably won't be able to create texture object for the eigenvector set.. (bug?). Object size is : %u bytes\n", bytes);
         if (getVerbosity() == QUDA_DEBUG_VERBOSE) printfQuda("\nEigenvector set constructor...\n");
         // create the associated even and odd subsets
         ColorSpinorParam param;
         param.siteSubset = QUDA_PARITY_SITE_SUBSET;
         param.nDim = nDim;
         memcpy(param.x, x, nDim*sizeof(int));
         param.create = QUDA_REFERENCE_FIELD_CREATE;
         param.v = v;
         param.norm = norm;
         param.eigv_dim  = eigv_dim;
         //reserve eigvector set
         eigenvectors.reserve(eigv_dim);
         //setup volume, [real_]length and stride for a single eigenvector
         for(int id = 0; id < eigv_dim; id++)
         {
            param.eigv_id = id;
            eigenvectors.push_back(new cudaColorSpinorField(*this, param));

#ifdef USE_TEXTURE_OBJECTS //(a lot of texture objects...)
            dynamic_cast<cudaColorSpinorField*>(eigenvectors[id])->destroyTexObject();
            dynamic_cast<cudaColorSpinorField*>(eigenvectors[id])->createTexObject();
#endif
         }
      }
    }

    if (create != QUDA_REFERENCE_FIELD_CREATE) {
      if (siteSubset != QUDA_FULL_SITE_SUBSET) {
	zeroPad();
      } else {
	(dynamic_cast<cudaColorSpinorField*>(even))->zeroPad();
	(dynamic_cast<cudaColorSpinorField*>(odd))->zeroPad();
      }
    }

#ifdef USE_TEXTURE_OBJECTS
    if((eigv_dim == 0) || (eigv_dim > 0 && eigv_id > -1))
       createTexObject();
#endif

    checkCudaError();
  }

#ifdef USE_TEXTURE_OBJECTS
  void cudaColorSpinorField::createTexObject() {
    if (isNative()) {
      if (texInit) errorQuda("Already bound textures");
      
      // create the texture for the field components
      
      cudaChannelFormatDesc desc;
      memset(&desc, 0, sizeof(cudaChannelFormatDesc));
      if (precision == QUDA_SINGLE_PRECISION) desc.f = cudaChannelFormatKindFloat;
      else desc.f = cudaChannelFormatKindSigned; // half is short, double is int2
      
      // staggered fields in half and single are always two component
      if (nSpin == 1 && (precision == QUDA_HALF_PRECISION || precision == QUDA_SINGLE_PRECISION)) {
	desc.x = 8*precision;
	desc.y = 8*precision;
	desc.z = 0;
	desc.w = 0;
      } else { // all others are four component
	desc.x = (precision == QUDA_DOUBLE_PRECISION) ? 32 : 8*precision;
	desc.y = (precision == QUDA_DOUBLE_PRECISION) ? 32 : 8*precision;
	desc.z = (precision == QUDA_DOUBLE_PRECISION) ? 32 : 8*precision;
	desc.w = (precision == QUDA_DOUBLE_PRECISION) ? 32 : 8*precision;
      }
      
      cudaResourceDesc resDesc;
      memset(&resDesc, 0, sizeof(resDesc));
      resDesc.resType = cudaResourceTypeLinear;
      resDesc.res.linear.devPtr = v;
      resDesc.res.linear.desc = desc;
      resDesc.res.linear.sizeInBytes = bytes;
      
      cudaTextureDesc texDesc;
      memset(&texDesc, 0, sizeof(texDesc));
      if (precision == QUDA_HALF_PRECISION) texDesc.readMode = cudaReadModeNormalizedFloat;
      else texDesc.readMode = cudaReadModeElementType;
      
      cudaCreateTextureObject(&tex, &resDesc, &texDesc, NULL);
      checkCudaError();
      
      // create the texture for the norm components
      if (precision == QUDA_HALF_PRECISION) {
	cudaChannelFormatDesc desc;
	memset(&desc, 0, sizeof(cudaChannelFormatDesc));
	desc.f = cudaChannelFormatKindFloat;
	desc.x = 8*QUDA_SINGLE_PRECISION; desc.y = 0; desc.z = 0; desc.w = 0;
	
	cudaResourceDesc resDesc;
	memset(&resDesc, 0, sizeof(resDesc));
	resDesc.resType = cudaResourceTypeLinear;
	resDesc.res.linear.devPtr = norm;
	resDesc.res.linear.desc = desc;
	resDesc.res.linear.sizeInBytes = norm_bytes;
	
	cudaTextureDesc texDesc;
	memset(&texDesc, 0, sizeof(texDesc));
	texDesc.readMode = cudaReadModeElementType;
	
	cudaCreateTextureObject(&texNorm, &resDesc, &texDesc, NULL);
	checkCudaError();
      }
      
      texInit = true;
    }
  }

  void cudaColorSpinorField::destroyTexObject() {
    if (isNative() && texInit) {
      cudaDestroyTextureObject(tex);
      if (precision == QUDA_HALF_PRECISION) cudaDestroyTextureObject(texNorm);
      texInit = false;
      checkCudaError();
    }
  }
#endif

  void cudaColorSpinorField::destroy() {
    if (alloc) {
      device_free(v);
      if (precision == QUDA_HALF_PRECISION) device_free(norm);
      if (siteSubset == QUDA_FULL_SITE_SUBSET) {
	delete even;
	delete odd;
      }
      else{
        //! for deflated solvers:
        if (eigv_dim > 0) 
        {
          std::vector<ColorSpinorField*>::iterator vec;
          for(vec = eigenvectors.begin(); vec != eigenvectors.end(); vec++) delete *vec;
        } 
      }
      alloc = false;
    }

#ifdef USE_TEXTURE_OBJECTS
    if((eigv_dim == 0) || (eigv_dim > 0 && eigv_id > -1))
       destroyTexObject();
#endif

  }

  cudaColorSpinorField& cudaColorSpinorField::Even() const { 
    if (siteSubset == QUDA_FULL_SITE_SUBSET) {
      return *(dynamic_cast<cudaColorSpinorField*>(even)); 
    }

    errorQuda("Cannot return even subset of %d subset", siteSubset);
    exit(-1);
  }

  cudaColorSpinorField& cudaColorSpinorField::Odd() const {
    if (siteSubset == QUDA_FULL_SITE_SUBSET) {
      return *(dynamic_cast<cudaColorSpinorField*>(odd)); 
    }

    errorQuda("Cannot return odd subset of %d subset", siteSubset);
    exit(-1);
  }

  // cuda's floating point format, IEEE-754, represents the floating point
  // zero as 4 zero bytes
  void cudaColorSpinorField::zero() {
    cudaMemsetAsync(v, 0, bytes, streams[Nstream-1]);
    if (precision == QUDA_HALF_PRECISION) cudaMemsetAsync(norm, 0, norm_bytes, streams[Nstream-1]);
  }

//! for the deflated solvers:
  void cudaColorSpinorField::zeroPad() {
    size_t pad_bytes = (stride - volume) * precision * fieldOrder;
    int Npad = nColor * nSpin * 2 / fieldOrder;//number of vector regs per site
 
    if (eigv_dim > 0 && eigv_id == -1){//we consider the whole eigenvector set:
      Npad      *= eigv_dim;//!
      pad_bytes /= eigv_dim;//!
    }
    size_t pitch = ((eigv_dim == 0 || eigv_id != -1) ? stride : eigv_stride)*fieldOrder*precision;
    char   *dst  = (char*)v + ((eigv_dim == 0 || eigv_id != -1) ? volume : eigv_volume)*fieldOrder*precision;
    if(pad_bytes) cudaMemset2D(dst, pitch, 0, pad_bytes, Npad);
  }

/** Old version of the above routine:
  void cudaColorSpinorField::zeroPad() {
    size_t pad_bytes = (stride - volume) * precision * fieldOrder;
    int Npad = nColor * nSpin * 2 / fieldOrder;
    for (int i=0; i<Npad; i++) {
      if (pad_bytes) cudaMemset((char*)v + (volume + i*stride)*fieldOrder*precision, 0, pad_bytes);
    }
  }
*/
  void cudaColorSpinorField::copy(const cudaColorSpinorField &src) {
    checkField(*this, src);
    copyCuda(*this, src);
  }

  void cudaColorSpinorField::copySpinorField(const ColorSpinorField &src) {
    
    // src is on the device and is native
    if (typeid(src) == typeid(cudaColorSpinorField) && 
	isNative() && dynamic_cast<const cudaColorSpinorField &>(src).isNative()) {
      copy(dynamic_cast<const cudaColorSpinorField&>(src));
    } else if (typeid(src) == typeid(cudaColorSpinorField)) {
      copyGenericColorSpinor(*this, src, QUDA_CUDA_FIELD_LOCATION);
    } else if (typeid(src) == typeid(cpuColorSpinorField)) { // src is on the host
      loadSpinorField(src);
    } else {
      errorQuda("Unknown input ColorSpinorField %s", typeid(src).name());
    }
  } 

  void cudaColorSpinorField::loadSpinorField(const ColorSpinorField &src) {

    if (REORDER_LOCATION == QUDA_CPU_FIELD_LOCATION && 
	typeid(src) == typeid(cpuColorSpinorField)) {
      resizeBufferPinned(bytes + norm_bytes);
      memset(bufferPinned, 0, bytes+norm_bytes); // FIXME (temporary?) bug fix for padding

      copyGenericColorSpinor(*this, src, QUDA_CPU_FIELD_LOCATION, 
			     bufferPinned, 0, (char*)bufferPinned+bytes, 0);

      cudaMemcpy(v, bufferPinned, bytes, cudaMemcpyHostToDevice);
      cudaMemcpy(norm, (char*)bufferPinned+bytes, norm_bytes, cudaMemcpyHostToDevice);
    } else {
      if (typeid(src) == typeid(cpuColorSpinorField)) {
	resizeBufferDevice(src.Bytes()+src.NormBytes());
	cudaMemcpy(bufferDevice, src.V(), src.Bytes(), cudaMemcpyHostToDevice);
	cudaMemcpy((char*)bufferDevice+src.NormBytes(), src.Norm(), src.NormBytes(), cudaMemcpyHostToDevice);
      }

      void *Src = typeid(src) == typeid(cudaColorSpinorField) ? (void*)src.V() : bufferDevice;
      void *srcNorm = typeid(src) == typeid(cudaColorSpinorField) ?
	(void*)src.Norm() : (char*)bufferDevice + src.Bytes();

      cudaMemset(v, 0, bytes+norm_bytes); // FIXME (temporary?) bug fix for padding
      copyGenericColorSpinor(*this, src, QUDA_CUDA_FIELD_LOCATION, 0, Src, 0, srcNorm);
    }

    checkCudaError();
    return;
  }


  void cudaColorSpinorField::saveSpinorField(ColorSpinorField &dest) const {

    if (REORDER_LOCATION == QUDA_CPU_FIELD_LOCATION && typeid(dest) == typeid(cpuColorSpinorField)) {
      resizeBufferPinned(bytes+norm_bytes);
      cudaMemcpy(bufferPinned, v, bytes, cudaMemcpyDeviceToHost);
      cudaMemcpy((char*)bufferPinned+bytes, norm, norm_bytes, cudaMemcpyDeviceToHost);
      copyGenericColorSpinor(dest, *this, QUDA_CPU_FIELD_LOCATION, 0, bufferPinned, 0, (char*)bufferPinned+bytes);
    } else {
      if (typeid(dest)==typeid(cpuColorSpinorField)) resizeBufferDevice(dest.Bytes()+dest.NormBytes());
      void *dst = (typeid(dest)==typeid(cudaColorSpinorField)) ? dest.V() : bufferDevice;
      void *dstNorm = (typeid(dest)==typeid(cudaColorSpinorField)) ? 
	dest.Norm() : (char*)bufferDevice+dest.Bytes();

      copyGenericColorSpinor(dest, *this, QUDA_CUDA_FIELD_LOCATION, dst, v, dstNorm, 0);

      if (typeid(dest) == typeid(cpuColorSpinorField)) {
	cudaMemcpy(dest.V(), bufferDevice, dest.Bytes(), cudaMemcpyDeviceToHost);
	cudaMemcpy(dest.Norm(), (char*)bufferDevice+dest.Bytes(), dest.NormBytes(), cudaMemcpyDeviceToHost);
      }
    }

    checkCudaError();
    return;
  }

  void cudaColorSpinorField::allocateGhostBuffer(void) {
    int nFace = (nSpin == 1) ? 3 : 1; //3 faces for asqtad
    int Nint = nColor * nSpin * 2; // number of internal degrees of freedom
    if (nSpin == 4) Nint /= 2; // spin projection for Wilson

    // only allocate if not already allocated or precision is greater then previously
    if(initGhostFaceBuffer == 0 || precision > facePrecision){    

      if (initGhostFaceBuffer) device_free(ghostFaceBuffer); 

      // allocate a single contiguous buffer for the buffers
      size_t faceBytes = 0;
      for (int i=0; i<4; i++) {
	if(!commDimPartitioned(i)) continue;
	faceBytes += 2*nFace*ghostFace[i]*Nint*precision;
	// add extra space for the norms for half precision
	if (precision == QUDA_HALF_PRECISION) faceBytes += 2*nFace*ghostFace[i]*sizeof(float);
      }

      if (faceBytes > 0) {
	ghostFaceBuffer = device_malloc(faceBytes);
	initGhostFaceBuffer = 1;
	facePrecision = precision;
      }

    }

    size_t offset = 0;
    for (int i=0; i<4; i++) {
      if(!commDimPartitioned(i)) continue;
      
      backGhostFaceBuffer[i] = (void*)(((char*)ghostFaceBuffer) + offset);
      offset += nFace*ghostFace[i]*Nint*precision;
      if (precision == QUDA_HALF_PRECISION) offset += nFace*ghostFace[i]*sizeof(float);
      
      fwdGhostFaceBuffer[i] = (void*)(((char*)ghostFaceBuffer) + offset);
      offset += nFace*ghostFace[i]*Nint*precision;
      if (precision == QUDA_HALF_PRECISION) offset += nFace*ghostFace[i]*sizeof(float);
    }   
    
  }


  void cudaColorSpinorField::freeGhostBuffer(void)
  {
    if (!initGhostFaceBuffer) return;
  
    device_free(ghostFaceBuffer); 

    for(int i=0;i < 4; i++){
      if(!commDimPartitioned(i)) continue;
      backGhostFaceBuffer[i] = NULL;
      fwdGhostFaceBuffer[i] = NULL;
    }
    initGhostFaceBuffer = 0;  
  }

  // pack the ghost zone into a contiguous buffer for communications
  void cudaColorSpinorField::packGhost(const QudaParity parity, const int dagger, 
				       cudaStream_t *stream, void *buffer) 
  {
#ifdef MULTI_GPU
    void *packBuffer = buffer ? buffer : ghostFaceBuffer;
    packFace(packBuffer, *this, dagger, parity, *stream); 
#else
    errorQuda("packGhost not built on single-GPU build");
#endif

  }

  void cudaColorSpinorField::packTwistedGhost(const QudaParity parity, const int dagger, 
					      double a, double b, cudaStream_t *stream, void *buffer) 
  {
#ifdef MULTI_GPU
    void *packBuffer = buffer ? buffer : ghostFaceBuffer;
    packTwistedFace(packBuffer, *this, dagger, parity, a, b, *stream); 
#else
    errorQuda("packTwistedGhost not built on single-GPU build");
#endif

  }
 
  // send the ghost zone to the host
  void cudaColorSpinorField::sendGhost(void *ghost_spinor, const int dim, const QudaDirection dir,
				       const int dagger, cudaStream_t *stream) {

#ifdef MULTI_GPU
    int Nvec = (nSpin == 1 || precision == QUDA_DOUBLE_PRECISION) ? 2 : 4;
    int nFace = (nSpin == 1) ? 3 : 1; //3 faces for asqtad
    int Nint = (nColor * nSpin * 2) / (nSpin == 4 ? 2 : 1);  // (spin proj.) degrees of freedom

    if (dim !=3 || getKernelPackT() || getTwistPack()) { // use kernels to pack into contiguous buffers then a single cudaMemcpy

      size_t bytes = nFace*Nint*ghostFace[dim]*precision;
      if (precision == QUDA_HALF_PRECISION) bytes += nFace*ghostFace[dim]*sizeof(float);
      void* gpu_buf = 
	(dir == QUDA_BACKWARDS) ? this->backGhostFaceBuffer[dim] : this->fwdGhostFaceBuffer[dim];

      cudaMemcpyAsync(ghost_spinor, gpu_buf, bytes, cudaMemcpyDeviceToHost, *stream); 
    } else if(this->TwistFlavor() != QUDA_TWIST_NONDEG_DOUBLET){ // do multiple cudaMemcpys

      int Npad = Nint / Nvec; // number Nvec buffers we have
      int Nt_minus1_offset = (volume - nFace*ghostFace[3]); // N_t -1 = Vh-Vsh
      int offset = 0;
      if (nSpin == 1) {
	offset = (dir == QUDA_BACKWARDS) ? 0 : Nt_minus1_offset;
      } else if (nSpin == 4) {    
	// !dagger: send lower components backwards, send upper components forwards
	// dagger: send upper components backwards, send lower components forwards
	bool upper = dagger ? true : false; // Fwd is !Back  
	if (dir == QUDA_FORWARDS) upper = !upper;
	int lower_spin_offset = Npad*stride;
	if (upper) offset = (dir == QUDA_BACKWARDS ? 0 : Nt_minus1_offset);
	else offset = lower_spin_offset + (dir == QUDA_BACKWARDS ? 0 : Nt_minus1_offset);
      }
    
      // QUDA Memcpy NPad's worth. 
      //  -- Dest will point to the right beginning PAD. 
      //  -- Each Pad has size Nvec*Vsh Floats. 
      //  --  There is Nvec*Stride Floats from the start of one PAD to the start of the next

      void *dst = (char*)ghost_spinor;
      void *src = (char*)v + offset*Nvec*precision;
      size_t len = nFace*ghostFace[3]*Nvec*precision;     
      size_t spitch = stride*Nvec*precision;
      cudaMemcpy2DAsync(dst, len, src, spitch, len, Npad, cudaMemcpyDeviceToHost, *stream);

      if (precision == QUDA_HALF_PRECISION) {
	int norm_offset = (dir == QUDA_BACKWARDS) ? 0 : Nt_minus1_offset*sizeof(float);
	void *dst = (char*)ghost_spinor + nFace*Nint*ghostFace[3]*precision;
	void *src = (char*)norm + norm_offset;
	cudaMemcpyAsync(dst, src, nFace*ghostFace[3]*sizeof(float), cudaMemcpyDeviceToHost, *stream); 
      }
    }else{
      int flavorVolume = volume / 2;
      int flavorTFace  = ghostFace[3] / 2;
      int Npad = Nint / Nvec; // number Nvec buffers we have
      int flavor1_Nt_minus1_offset = (flavorVolume - flavorTFace);
      int flavor2_Nt_minus1_offset = (volume - flavorTFace);
      int flavor1_offset = 0;
      int flavor2_offset = 0;
      // !dagger: send lower components backwards, send upper components forwards
      // dagger: send upper components backwards, send lower components forwards
      bool upper = dagger ? true : false; // Fwd is !Back
      if (dir == QUDA_FORWARDS) upper = !upper;
      int lower_spin_offset = Npad*stride;//ndeg tm: stride=2*flavor_volume+pad
      if (upper){
        flavor1_offset = (dir == QUDA_BACKWARDS ? 0 : flavor1_Nt_minus1_offset);
        flavor2_offset = (dir == QUDA_BACKWARDS ? flavorVolume : flavor2_Nt_minus1_offset);
      }else{
        flavor1_offset = lower_spin_offset + (dir == QUDA_BACKWARDS ? 0 : flavor1_Nt_minus1_offset);
        flavor2_offset = lower_spin_offset + (dir == QUDA_BACKWARDS ? flavorVolume : flavor2_Nt_minus1_offset);
      }

      // QUDA Memcpy NPad's worth.
      //  -- Dest will point to the right beginning PAD.
      //  -- Each Pad has size Nvec*Vsh Floats.
      //  --  There is Nvec*Stride Floats from the start of one PAD to the start of the next

      void *dst = (char*)ghost_spinor;
      void *src = (char*)v + flavor1_offset*Nvec*precision;
      size_t len = flavorTFace*Nvec*precision;
      size_t spitch = stride*Nvec*precision;//ndeg tm: stride=2*flavor_volume+pad
      size_t dpitch = 2*len;
      cudaMemcpy2DAsync(dst, dpitch, src, spitch, len, Npad, cudaMemcpyDeviceToHost, *stream);
      dst = (char*)ghost_spinor+len;
      src = (char*)v + flavor2_offset*Nvec*precision;
      cudaMemcpy2DAsync(dst, dpitch, src, spitch, len, Npad, cudaMemcpyDeviceToHost, *stream);

      if (precision == QUDA_HALF_PRECISION) {
        int Nt_minus1_offset = (flavorVolume - flavorTFace);
        int norm_offset = (dir == QUDA_BACKWARDS) ? 0 : Nt_minus1_offset*sizeof(float);
	void *dst = (char*)ghost_spinor + Nint*ghostFace[3]*precision;
	void *src = (char*)norm + norm_offset;
        size_t dpitch = flavorTFace*sizeof(float);
        size_t spitch = flavorVolume*sizeof(float);
	cudaMemcpy2DAsync(dst, dpitch, src, spitch, flavorTFace*sizeof(float), 2, cudaMemcpyDeviceToHost, *stream);
      }
    }
#else
    errorQuda("sendGhost not built on single-GPU build");
#endif

  }


  void cudaColorSpinorField::unpackGhost(void* ghost_spinor, const int dim, 
					 const QudaDirection dir, 
					 const int dagger, cudaStream_t* stream) 
  {
    int nFace = (nSpin == 1) ? 3 : 1; //3 faces for asqtad
    int Nint = (nColor * nSpin * 2) / (nSpin == 4 ? 2 : 1);  // (spin proj.) degrees of freedom

    int len = nFace*ghostFace[dim]*Nint;
    int offset = length + ghostOffset[dim]*nColor*nSpin*2;
    offset += (dir == QUDA_BACKWARDS) ? 0 : len;

    void *dst = (char*)v + precision*offset;
    void *src = ghost_spinor;

    cudaMemcpyAsync(dst, src, len*precision, cudaMemcpyHostToDevice, *stream);
    
    if (precision == QUDA_HALF_PRECISION) {
      int normlen = nFace*ghostFace[dim];
      int norm_offset = stride + ghostNormOffset[dim];
      norm_offset += (dir == QUDA_BACKWARDS) ? 0 : normlen;

      void *dst = (char*)norm + norm_offset*sizeof(float);
      void *src = (char*)ghost_spinor+nFace*Nint*ghostFace[dim]*precision; // norm region of host ghost zone
      cudaMemcpyAsync(dst, src, normlen*sizeof(float), cudaMemcpyHostToDevice, *stream);
    }

  }

  // Return the location of the field
  QudaFieldLocation cudaColorSpinorField::Location() const { return QUDA_CUDA_FIELD_LOCATION; }

  std::ostream& operator<<(std::ostream &out, const cudaColorSpinorField &a) {
    out << (const ColorSpinorField&)a;
    out << "v = " << a.v << std::endl;
    out << "norm = " << a.norm << std::endl;
    out << "alloc = " << a.alloc << std::endl;
    out << "init = " << a.init << std::endl;
    return out;
  }

//! for deflated solvers:
  cudaColorSpinorField& cudaColorSpinorField::Eigenvec(const int idx) const {
    
    if (siteSubset == QUDA_PARITY_SITE_SUBSET && this->EigvId() == -1) {
      if (idx < this->EigvDim()) {//setup eigenvector form the set
        return *(dynamic_cast<cudaColorSpinorField*>(eigenvectors[idx])); 
      }
      else{
        errorQuda("Incorrect eigenvector index...");
      }
    }
    errorQuda("Eigenvector must be a parity spinor");
    exit(-1);
  }

//copyCuda currently cannot not work with set of spinor fields..
  void cudaColorSpinorField::CopyEigenvecSubset(cudaColorSpinorField &dst, const int range, const int first_element) const{
#if 0
    if(first_element < 0) errorQuda("\nError: trying to set negative first element.\n");
    if (siteSubset == QUDA_PARITY_SITE_SUBSET && this->EigvId() == -1) {
      if (first_element == 0 && range == this->EigvDim())
      {
        if(range != dst.EigvDim())errorQuda("\nError: eigenvector range to big.\n");
        checkField(dst, *this);
        copyCuda(dst, *this);
      }
      else if ((first_element+range) < this->EigvDim()) 
      {//setup eigenvector subset

        cudaColorSpinorField *eigv_subset;

        ColorSpinorParam param;

        param.nColor = nColor;
        param.nSpin = nSpin;
        param.twistFlavor = twistFlavor;
        param.precision = precision;
        param.nDim = nDim;
        param.pad = pad;
        param.siteSubset = siteSubset;
        param.siteOrder = siteOrder;
        param.fieldOrder = fieldOrder;
        param.gammaBasis = gammaBasis;
        memcpy(param.x, x, nDim*sizeof(int));
        param.create = QUDA_REFERENCE_FIELD_CREATE;
 
        param.eigv_dim  = range;
        param.eigv_id   = -1;
        param.v = (void*)((char*)v + first_element*eigv_bytes);
        param.norm = (void*)((char*)norm + first_element*eigv_norm_bytes);

        eigv_subset = new cudaColorSpinorField(param);

        //Not really needed:
        eigv_subset->eigenvectors.reserve(param.eigv_dim);
        for(int id = first_element; id < (first_element+range); id++)
        {
            param.eigv_id = id;
            eigv_subset->eigenvectors.push_back(new cudaColorSpinorField(*this, param));
        }
        checkField(dst, *eigv_subset);
        copyCuda(dst, *eigv_subset);

        delete eigv_subset;
      }
      else{
        errorQuda("Incorrect eigenvector dimension...");
      }
    }
    else{  
      errorQuda("Eigenvector must be a parity spinor");
      exit(-1);
    }
#endif
  }

  void cudaColorSpinorField::getTexObjectInfo() const
  {
#ifdef USE_TEXTURE_OBJECTS
    printfQuda("\nPrint texture info for the field:\n");
    std::cout << *this;
    cudaResourceDesc resDesc;
    //memset(&resDesc, 0, sizeof(resDesc));
    cudaGetTextureObjectResourceDesc(&resDesc, this->Tex());
    printfQuda("\nDevice pointer: %p\n", resDesc.res.linear.devPtr);
    printfQuda("\nVolume (in bytes): %d\n", resDesc.res.linear.sizeInBytes);
    if (resDesc.resType == cudaResourceTypeLinear) printfQuda("\nResource type: linear \n");
    checkCudaError();
#endif
  }
} // namespace quda

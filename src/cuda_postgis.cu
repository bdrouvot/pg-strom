/*
 * cuda_postgis.cu
 *
 * Routines of basic PostGIS functions & operators for CUDA GPU devices
 * --
 * Copyright 2011-2020 (C) KaiGai Kohei <kaigai@kaigai.gr.jp>
 * Copyright 2014-2020 (C) The PG-Strom Development Team
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */
#include "cuda_common.h"
#include "cuda_postgis.h"

/* ================================================================
 *
 * Internal Utility Routines
 *
 * ================================================================ */

/*
 * Floating point comparators. (see, liblwgeom_internal.h)
 */
#define FP_TOLERANCE 1e-12
#define FP_IS_ZERO(A) (fabs(A) <= FP_TOLERANCE)
#define FP_MAX(A, B) (((A) > (B)) ? (A) : (B))
#define FP_MIN(A, B) (((A) < (B)) ? (A) : (B))
#define FP_ABS(a)   ((a) <  (0) ? -(a) : (a))
#define FP_EQUALS(A, B) (fabs((A)-(B)) <= FP_TOLERANCE)
#define FP_NEQUALS(A, B) (fabs((A)-(B)) > FP_TOLERANCE)
#define FP_LT(A, B) (((A) + FP_TOLERANCE) < (B))
#define FP_LTEQ(A, B) (((A) - FP_TOLERANCE) <= (B))
#define FP_GT(A, B) (((A) - FP_TOLERANCE) > (B))
#define FP_GTEQ(A, B) (((A) + FP_TOLERANCE) >= (B))
#define FP_CONTAINS_TOP(A, X, B) (FP_LT(A, X) && FP_LTEQ(X, B))
#define FP_CONTAINS_BOTTOM(A, X, B) (FP_LTEQ(A, X) && FP_LT(X, B))
#define FP_CONTAINS_INCL(A, X, B) (FP_LTEQ(A, X) && FP_LTEQ(X, B))
#define FP_CONTAINS_EXCL(A, X, B) (FP_LT(A, X) && FP_LT(X, B))
#define FP_CONTAINS(A, X, B) FP_CONTAINS_EXCL(A, X, B)

STATIC_INLINE(cl_uint)
geometry_points_unitsz(pg_geometry_t *geom)
{
	return sizeof(double) * GEOM_FLAGS_NDIMS(geom->flags);
}

STATIC_INLINE(cl_bool)
geometry_type_is_collection(cl_int geom_type)
{
	/* see lw_dist2d_is_collection */
	if (geom_type == GEOM_TINTYPE ||
		geom_type == GEOM_MULTIPOINTTYPE ||
		geom_type == GEOM_MULTILINETYPE ||
		geom_type == GEOM_MULTIPOLYGONTYPE ||
		geom_type == GEOM_COLLECTIONTYPE ||
		geom_type == GEOM_MULTICURVETYPE ||
		geom_type == GEOM_MULTISURFACETYPE ||
		geom_type == GEOM_COMPOUNDTYPE ||
		geom_type == GEOM_POLYHEDRALSURFACETYPE)
		return true;

	return false;
}

STATIC_FUNCTION(cl_bool)
setup_geometry_rawsize(pg_geometry_t *geom)
{
	switch (geom->type)
	{
		case GEOM_POINTTYPE:
		case GEOM_LINETYPE:
		case GEOM_TRIANGLETYPE:
		case GEOM_CIRCSTRINGTYPE:
			geom->rawsize = (sizeof(double) *
							 GEOM_FLAGS_NDIMS(geom->flags) * geom->nitems);
			return true;
		case GEOM_POLYGONTYPE:
			{
				size_t		rawsize = LONGALIGN(sizeof(cl_uint)*geom->nitems);
				const char *rawdata = geom->rawdata;
				cl_uint		__nitems;

				for (int i=0; i < geom->nitems; i++)
				{
					memcpy(&__nitems, rawdata, sizeof(cl_uint));
					rawdata += sizeof(cl_uint);
					rawsize += (sizeof(double) *
								GEOM_FLAGS_NDIMS(geom->flags) * __nitems);
				}
				geom->rawsize = rawsize;
			}
			return true;
		case GEOM_MULTIPOINTTYPE:
		case GEOM_MULTILINETYPE:
		case GEOM_MULTIPOLYGONTYPE:
		case GEOM_COLLECTIONTYPE:
		case GEOM_COMPOUNDTYPE:
		case GEOM_CURVEPOLYTYPE:
		case GEOM_MULTICURVETYPE:
		case GEOM_MULTISURFACETYPE:
		case GEOM_POLYHEDRALSURFACETYPE:
		case GEOM_TINTYPE:
			{
				const char *pos = geom->rawdata;
				for (int i=0; i < geom->nitems; i++)
				{
					pg_geometry_t __geom;

					__geom.type = __Fetch((cl_int *)pos);
					pos += sizeof(cl_int);
					__geom.flags = geom->flags;
					__geom.nitems = __Fetch((cl_uint *)pos);
					pos += sizeof(cl_uint);
					if (!setup_geometry_rawsize(&__geom))
						return false;
					pos += __geom.rawsize;
				}
				geom->rawsize = (pos - geom->rawdata);
			}
			return true;
		default:
			/* unknown geometry type */
			break;
	}
	return false;
}

/* ================================================================
 *
 * GSERIALIZED v1/v2 (see, gserialized1.h and gserialized2.h)
 *
 * ================================================================
 */
STATIC_INLINE(cl_int)
__gserialized_get_srid(const __GSERIALIZED *gs)
{
	cl_int		srid;

	/* Only the first 21 bits are set. Slide up and back to pull
	 * the negative bits down, if we need them. */
	srid = (((cl_uint)gs->srid[0] << 16) |
			((cl_uint)gs->srid[1] <<  8) |
			((cl_uint)gs->srid[0]));
	srid = (srid << 11) >> 11;
	/* 0 is our internal unknown value */
	return (srid == 0 ? SRID_UNKNOWN : srid);
}

STATIC_FUNCTION(pg_geometry_t)
__geometry_datum_ref_v1(kern_context *kcxt, void *addr, cl_int sz)
{
	/* see lwgeom_from_gserialized1() */
	__GSERIALIZED  *gs = (__GSERIALIZED *)addr;
	pg_geometry_t	geom;
	cl_ushort		geom_flags = 0;
	char		   *rawdata = gs->data;

	memset(&geom, 0, sizeof(pg_geometry_t));
	if ((gs->gflags & G1FLAG_Z) != 0)
		geom_flags |= GEOM_FLAG__Z;
	if ((gs->gflags & G1FLAG_M) != 0)
		geom_flags |= GEOM_FLAG__M;
	if ((gs->gflags & G1FLAG_BBOX) != 0)
		geom_flags |= GEOM_FLAG__BBOX;
	if ((gs->gflags & G1FLAG_GEODETIC) != 0)
		geom_flags |= GEOM_FLAG__GEODETIC;
	if ((gs->gflags & G1FLAG_SOLID) != 0)
		geom_flags |= GEOM_FLAG__SOLID;

	geom.flags = geom_flags;
	geom.srid = __gserialized_get_srid(gs);
	if ((geom.flags & GEOM_FLAG__BBOX) != 0)
	{
		geom.bbox = (geom_bbox *)rawdata;
		rawdata += geometry_bbox_size(geom.flags);
	}
	memcpy(&geom.type, rawdata, sizeof(cl_uint));
	rawdata += sizeof(cl_uint);
	memcpy(&geom.nitems, rawdata, sizeof(cl_uint));
	rawdata += sizeof(cl_uint);
	geom.rawdata = rawdata;
	if (!setup_geometry_rawsize(&geom) ||
		geom.rawdata + geom.rawsize > gs->data + sz)
	{
		STROM_EREPORT(kcxt, ERRCODE_DATA_CORRUPTED,
					  "geometry data v1 corrupted");
		geom.isnull = true;
	}
	/*
	 * NOTE: Unlike CPU version of lwgeom_from_gserialized1(),
	 * we don't generate boundary box here, even if raw geometry
	 * datum has no boundary box unexpectedly. It is mandatorily
	 * generated by PostGIS, thus the code to construct bounday
	 * box just consumes device memory footpoint, and we have no
	 * proper way for code debugging.
	 */
	return geom;
}

/* flags of GSERIALIZED v2 */

STATIC_FUNCTION(pg_geometry_t)
__geometry_datum_ref_v2(kern_context *kcxt, void *addr, cl_int sz)
{
	/* see lwgeom_from_gserialized2() */
	__GSERIALIZED  *gs = (__GSERIALIZED *)addr;
	pg_geometry_t	geom;
	cl_uchar		gs_flags = gs->gflags;
	cl_ushort		geom_flags = 0;
	char		   *rawdata = gs->data;

	memset(&geom, 0, sizeof(pg_geometry_t));

	/* parse version.2 flags */
	if ((gs_flags & G2FLAG_Z) != 0)
		geom_flags |= GEOM_FLAG__Z;
	if ((gs_flags & G2FLAG_M) != 0)
		geom_flags |= GEOM_FLAG__M;
	if ((gs_flags & G2FLAG_BBOX) != 0)
		geom_flags |= GEOM_FLAG__BBOX;
    if ((gs_flags & G2FLAG_GEODETIC) != 0)
		geom_flags |= G1FLAG_GEODETIC;
	if ((gs_flags & G2FLAG_EXTENDED) != 0)
	{
		cl_ulong    ex_flags;

		memcpy(&ex_flags, rawdata, sizeof(cl_ulong));
		if ((ex_flags & G2FLAG_X_SOLID) != 0)
			geom_flags |= GEOM_FLAG__SOLID;
		rawdata += sizeof(cl_ulong);
	}
	geom.flags = geom_flags;
	geom.srid = __gserialized_get_srid(gs);
	if ((geom.flags & GEOM_FLAG__BBOX) != 0)
	{
		geom.bbox = (geom_bbox *)rawdata;
		rawdata += geometry_bbox_size(geom.flags);
	}
	memcpy(&geom.type, rawdata, sizeof(cl_uint));
	rawdata += sizeof(cl_uint);
	memcpy(&geom.nitems, rawdata, sizeof(cl_uint));
	rawdata += sizeof(cl_uint);
	geom.rawdata = rawdata;
	if (!setup_geometry_rawsize(&geom) ||
		geom.rawdata + geom.rawsize > gs->data + sz)
	{
		STROM_EREPORT(kcxt, ERRCODE_DATA_CORRUPTED,
					  "geometry data v2 corrupted");
		geom.isnull = true;
	}
	/*
	 * NOTE: Unlike CPU version of lwgeom_from_gserialized1(),
	 * we don't generate boundary box here, even if raw geometry
	 * datum has no boundary box unexpectedly. It is mandatorily
	 * generated by PostGIS, thus the code to construct bounday
	 * box just consumes device memory footpoint, and we have no
	 * proper way for code debugging.
	 */
	return geom;
}

DEVICE_FUNCTION(pg_geometry_t)
pg_geometry_datum_ref(kern_context *kcxt, void *addr)
{
	pg_geometry_t	result;

	if (!addr)
	{
		memset(&result, 0, sizeof(pg_geometry_t));
		result.isnull = true;
	}
	else
	{
		__GSERIALIZED  *g = (__GSERIALIZED *)VARDATA_ANY(addr);
		cl_int			sz = VARSIZE_ANY_EXHDR(addr);

		if ((g->gflags & G2FLAG_VER_0) != 0)
			result = __geometry_datum_ref_v2(kcxt, g, sz);
		else
			result = __geometry_datum_ref_v1(kcxt, g, sz);
	}
	return result;
}

DEVICE_FUNCTION(void)
pg_datum_ref(kern_context *kcxt, pg_geometry_t &result, void *addr)
{
	result = pg_geometry_datum_ref(kcxt, addr);
}

DEVICE_FUNCTION(void)
pg_datum_ref_slot(kern_context *kcxt,
				  pg_geometry_t &result,
				  cl_char dclass, Datum datum)
{
	if (dclass == DATUM_CLASS__NULL)
		result = pg_geometry_datum_ref(kcxt, NULL);
	else if (dclass == DATUM_CLASS__GEOMETRY)
		memcpy(&result, DatumGetPointer(datum), sizeof(pg_geometry_t));
	else
	{
		assert(dclass == DATUM_CLASS__NORMAL);
		result = pg_geometry_datum_ref(kcxt, (char *)datum);
	}
}

DEVICE_FUNCTION(pg_geometry_t)
pg_geometry_param(kern_context *kcxt, cl_uint param_id)
{
	kern_parambuf *kparams = kcxt->kparams;
	pg_geometry_t result;

	if (param_id < kparams->nparams &&
		kparams->poffset[param_id] > 0)
	{
		void   *addr = ((char *)kparams +
						kparams->poffset[param_id]);
		result = pg_geometry_datum_ref(kcxt, addr);
	}
	else
	{
		memset(&result, 0, sizeof(pg_geometry_t));
		result.isnull = true;
	}
	return result;
}

DEVICE_FUNCTION(cl_int)
pg_datum_store(kern_context *kcxt,
			   pg_geometry_t datum,
			   cl_char &dclass,
			   Datum &value)
{
	if (datum.isnull)
		dclass = DATUM_CLASS__NULL;
	else
	{
		pg_geometry_t *temp;

		temp = (pg_geometry_t *)
			kern_context_alloc(kcxt, sizeof(pg_geometry_t));
		if (temp)
		{
			memcpy(temp, &datum, sizeof(pg_geometry_t));
			dclass = DATUM_CLASS__GEOMETRY;
			value = PointerGetDatum(temp);
			return sizeof(pg_geometry_t);
		}
		STROM_EREPORT(kcxt, ERRCODE_OUT_OF_MEMORY,
					  "out of memory");
		dclass = DATUM_CLASS__NULL;
	}
	return 0;
}

/* ================================================================
 *
 * Basic geometry constructor and related
 *
 * ================================================================
 */
DEVICE_FUNCTION(pg_geometry_t)
pgfn_st_setsrid(kern_context *kcxt, const pg_geometry_t &arg1, pg_int4_t arg2)
{
	pg_geometry_t	result;

	if (arg1.isnull || arg2.isnull)
	{
		memset(&result, 0, sizeof(pg_geometry_t));
		result.isnull = true;
	}
	else
	{
		/* see clamp_srid */
		cl_int	srid = arg2.value;

		if (srid <= 0)
			srid = SRID_UNKNOWN;
		else if (srid > SRID_MAXIMUM)
			srid = SRID_USER_MAXIMUM + 1 +
				(srid % (SRID_MAXIMUM - SRID_USER_MAXIMUM - 1));
		memcpy(&result, &arg1, sizeof(pg_geometry_t));
		result.srid = srid;
	}
	return result;
}

DEVICE_FUNCTION(pg_geometry_t)
pgfn_st_makepoint2(kern_context *kcxt, pg_float8_t x, pg_float8_t y)
{
	pg_geometry_t	geom;

	memset(&geom, 0, sizeof(pg_geometry_t));
	if (x.isnull || y.isnull)
		geom.isnull = true;
	else
	{
		cl_double  *rawdata = (cl_double *)
			kern_context_alloc(kcxt, 2 * sizeof(cl_double));

		if (!rawdata)
		{
			STROM_CPU_FALLBACK(kcxt, ERRCODE_OUT_OF_MEMORY,
							   "out of memory");
			geom.isnull = true;
		}
		else
		{
			rawdata[0] = x.value;
			rawdata[1] = y.value;

			geom.type = GEOM_POINTTYPE;
			geom.flags = 0;
			geom.srid = SRID_UNKNOWN;
			geom.nitems = 1;
			geom.rawsize = 2 * sizeof(cl_double);
			geom.rawdata = (char *)rawdata;
		}
	}
	return geom;
}

DEVICE_FUNCTION(pg_geometry_t)
pgfn_st_makepoint3(kern_context *kcxt,
				   pg_float8_t x, pg_float8_t y, pg_float8_t z)
{
	pg_geometry_t	geom;

	memset(&geom, 0, sizeof(pg_geometry_t));
	if (x.isnull || y.isnull || z.isnull)
		geom.isnull = true;
	else
	{
		cl_double  *rawdata = (cl_double *)
			kern_context_alloc(kcxt, 3 * sizeof(cl_double));

		if (!rawdata)
		{
			STROM_CPU_FALLBACK(kcxt, ERRCODE_OUT_OF_MEMORY,
							   "out of memory");
			geom.isnull = true;
		}
		else
		{
			rawdata[0] = x.value;
			rawdata[1] = y.value;
			rawdata[2] = z.value;

			geom.type = GEOM_POINTTYPE;
			geom.flags = GEOM_FLAG__Z;
			geom.srid = SRID_UNKNOWN;
			geom.nitems = 1;
			geom.rawsize = 3 * sizeof(cl_double);
			geom.rawdata = (char *)rawdata;
		}
	}
	return geom;
}

DEVICE_FUNCTION(pg_geometry_t)
pgfn_st_makepoint4(kern_context *kcxt,
				   pg_float8_t x, pg_float8_t y,
				   pg_float8_t z, pg_float8_t m)
{
	pg_geometry_t	geom;

	memset(&geom, 0, sizeof(pg_geometry_t));
	if (x.isnull || y.isnull || z.isnull || m.isnull)
		geom.isnull = true;
	else
	{
		cl_double  *rawdata = (cl_double *)
			kern_context_alloc(kcxt, 4 * sizeof(cl_double));

		if (!rawdata)
		{
			STROM_CPU_FALLBACK(kcxt, ERRCODE_OUT_OF_MEMORY,
							   "out of memory");
			geom.isnull = true;
		}
		else
		{
			rawdata[0] = x.value;
			rawdata[1] = y.value;
			rawdata[2] = z.value;
			rawdata[3] = m.value;

			geom.type = GEOM_POINTTYPE;
			geom.flags = GEOM_FLAG__Z | GEOM_FLAG__M;
			geom.srid = SRID_UNKNOWN;
			geom.nitems = 1;
			geom.rawsize = 2 * sizeof(cl_double);
			geom.rawdata = (char *)rawdata;
		}
	}
	return geom;
}

/* ================================================================
 *
 * St_Distance(geometry,geometry)
 *
 * ================================================================
 */
STATIC_INLINE(const char *)
__loadPoint2d(POINT2D *pt, const char *rawdata, cl_uint unitsz)
{
	memcpy(pt, rawdata, sizeof(POINT2D));
	return rawdata + unitsz;
}

STATIC_FUNCTION(const char *)
__load_sub_geometry(pg_geometry_t *gsub,
					const pg_geometry_t *geom, const char *pos, int index)
{
	switch (geom->type)
	{
		case GEOM_POINTTYPE:
		case GEOM_LINETYPE:
		case GEOM_TRIANGLETYPE:
		case GEOM_CIRCSTRINGTYPE:
			/* no sub-geometry */
			break;
		case GEOM_POLYGONTYPE:
			if (index == 0)
				pos = geom->rawdata + LONGALIGN(sizeof(cl_int) * geom->nitems);
			else if (index >= geom->nitems)
				break;
			gsub->isnull = false;
			gsub->type   = GEOM_LINETYPE;
			gsub->flags  = geom->flags;
			gsub->srid   = geom->srid;
			gsub->nitems = __Fetch(((cl_uint *)geom->rawdata) + index);
			gsub->rawdata = pos;
			gsub->bbox   = geom->bbox;
			setup_geometry_rawsize(gsub);
			pos += gsub->rawsize;
			return pos;

		case GEOM_MULTIPOINTTYPE:
        case GEOM_MULTILINETYPE:
        case GEOM_MULTIPOLYGONTYPE:
        case GEOM_COLLECTIONTYPE:
        case GEOM_COMPOUNDTYPE:
        case GEOM_CURVEPOLYTYPE:
        case GEOM_MULTICURVETYPE:
        case GEOM_MULTISURFACETYPE:
        case GEOM_POLYHEDRALSURFACETYPE:
        case GEOM_TINTYPE:
			if (index == 0)
				pos = geom->rawdata;
			else if (index >= geom->nitems)
				break;
			gsub->isnull = false;
			gsub->type = __Fetch((cl_int *)pos);
			pos += sizeof(cl_int);
			gsub->flags = geom->flags;
			gsub->srid = geom->srid;
			gsub->nitems = __Fetch((cl_uint *)pos);
			pos += sizeof(cl_uint);
			gsub->rawdata = pos;
			gsub->bbox = geom->bbox;
			setup_geometry_rawsize(gsub);
			pos += gsub->rawsize;
			return pos;

		default:
			/* unknown geometry type */
			break;
	}
	memset(gsub, 0, sizeof(pg_geometry_t));
	gsub->isnull = true;
	return NULL;
}

STATIC_INLINE(int)
__geom_segment_side(const POINT2D *p1, const POINT2D *p2, const POINT2D *q)
{
	double	side = ((q->x - p1->x) * (p2->y - p1->y) -
					(p2->x - p1->x) * (q->y - p1->y));
	return (side < 0.0 ? -1 : (side > 0.0 ? 1 : 0));
}

STATIC_INLINE(cl_bool)
__geom_pt_in_arc(const POINT2D *P,
				 const POINT2D *A1,
				 const POINT2D *A2,
				 const POINT2D *A3)
{
	return __geom_segment_side(A1, A3, A2) == __geom_segment_side(A1, A3, P);
}

STATIC_INLINE(cl_bool)
__geom_pt_in_seg(const POINT2D *P,
				 const POINT2D *A1,
				 const POINT2D *A2)
{
	return ((A1->x <= P->x && P->x < A2->x) ||
			(A1->x >= P->x && P->x > A2->x) ||
			(A1->y <= P->y && P->y < A2->y) ||
			(A1->y >= P->y && P->y > A2->y));
}

/*
 * state object used in distance-calculations
 */
typedef struct
{
	kern_context *kcxt;	/* for error reporting */
	double		distance;
	POINT2D		p1;
	POINT2D		p2;
	int			twisted;/* to preserve the order of incoming points */
} DISTPTS;

#define PT_INSIDE		1
#define PT_BOUNDARY		0
#define PT_OUTSIDE		(-1)
#define PT_ERROR		9999

STATIC_FUNCTION(int)
__geom_contains_point_partial(const pg_geometry_t *geom,
							  const POINT2D *pt,
							  cl_bool check_closed,
							  DISTPTS *dl)
{
	/* see ptarray_contains_point_partial */
	cl_uint		unitsz = sizeof(double) * GEOM_FLAGS_NDIMS(geom->flags);
	POINT2D		seg1, seg2;
	int			side, wn = 0;

	__loadPoint2d(&seg1, geom->rawdata, unitsz);
	__loadPoint2d(&seg2, geom->rawdata + unitsz * (geom->nitems-1), unitsz);
	if (check_closed && (!FP_EQUALS(seg1.x, seg2.x) ||
						 !FP_EQUALS(seg1.y, seg2.y)))
	{
		STROM_EREPORT(dl->kcxt, ERRCODE_DATA_CORRUPTED,
					  "__geom_contains_point called on unclosed ring");
		return PT_ERROR;
	}

	for (int i=1; i < geom->nitems; i++, seg1 = seg2)
	{
		__loadPoint2d(&seg2, geom->rawdata + i * unitsz, unitsz);
		/* zero length segments are ignored. */
		if (seg1.x == seg2.x && seg1.y == seg2.y)
			continue;

		/* only test segments in our vertical range */
		if (pt->y > Max(seg1.y, seg2.y) ||
			pt->y < Min(seg1.y, seg2.y))
			continue;

		side = __geom_segment_side(&seg1, &seg2, pt);
		if (side == 0 && __geom_pt_in_seg(pt, &seg1, &seg2))
			return PT_BOUNDARY;

		if (side < 0 && seg1.y <= pt->y && pt->y < seg2.y)
		{
			/*
			 * If the point is to the left of the line, and it's rising,
			 * then the line is to the right of the point and
			 * circling counter-clockwise, so increment.
			 */
			wn++;
		}
		else if (side > 0 && seg2.y <= pt->y && pt->y < seg1.y)
		{
			/*
			 * If the point is to the right of the line, and it's falling,
			 * then the line is to the right of the point and circling
			 * clockwise, so decrement.
			 */
			wn--;
		}
	}
	return (wn == 0 ? PT_OUTSIDE : PT_INSIDE);
}

STATIC_INLINE(int)
__geom_contains_point(const pg_geometry_t *geom,
					  const POINT2D *pt,
					  DISTPTS *dl)
{
	return __geom_contains_point_partial(geom, pt, true, dl);
}

STATIC_INLINE(cl_bool)
__geom_dist2d_pt_pt(const POINT2D *p1,
					const POINT2D *p2,
					DISTPTS *dl)
{
	/* see lw_dist2d_pt_pt */
	double	dist = hypot(p1->x - p2->x, p1->y - p2->y);

	if (dl->distance > dist)
	{
		dl->distance = dist;
		if (dl->twisted > 0)
		{
			dl->p1 = *p1;
			dl->p2 = *p2;
		}
		else
		{
			dl->p1 = *p2;
			dl->p2 = *p1;
		}
	}
	return true;
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_pt_seg(const POINT2D *pt,
					 const POINT2D *A,
					 const POINT2D *B,
					 DISTPTS *dl)
{
	/* see lw_dist2d_pt_seg */
	POINT2D		c;
	double		r;

	/* if start==end, then use pt distance  */
	if (FP_EQUALS(A->x, B->x) && FP_EQUALS(A->y, B->y))
		return __geom_dist2d_pt_pt(pt, A, dl);

	/*
	 * otherwise, we use comp.graphics.algorithms
	 * Frequently Asked Questions method
	 *
	 *  (1)        AC dot AB
	 *         r = ---------
	 *              ||AB||^2
	 *  r has the following meaning:
	 *  r=0 P = A
	 *  r=1 P = B
	 *  r<0 P is on the backward extension of AB
	 *  r>1 P is on the forward extension of AB
	 *  0<r<1 P is interior to AB
	 */
	r = ((pt->x - A->x) * (B->x - A->x) + (pt->y - A->y) * (B->y - A->y)) /
		((B->x - A->x) * (B->x - A->x) + (B->y - A->y) * (B->y - A->y));

	/* If p projected on the line is outside point A */
	if (r < 0.0)
		return __geom_dist2d_pt_pt(pt, A, dl);
	/* If p projected on the line is outside point B or on point B */
	if (r >= 1.0)
		return __geom_dist2d_pt_pt(pt, B, dl);
	/*
	 * If the point pt is on the segment this is a more robust way
	 * to find out that
	 */
	if ((A->y - pt->y) * (B->x - A->x) == (A->x - pt->x) * (B->y - A->y))
	{
		dl->distance = 0.0;
		dl->p1 = *pt;
		dl->p2 = *pt;
	}
	/*
	 * If the projection of point p on the segment is between A and B
	 * then we find that "point on segment" and send it to __geom_dist2d_pt_pt
	 */
	c.x = A->x + r * (B->x - A->x);
	c.y = A->y + r * (B->y - A->y);

	return __geom_dist2d_pt_pt(pt, &c, dl);
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_seg_seg(const POINT2D *A,
					  const POINT2D *B,
					  const POINT2D *C,
					  const POINT2D *D,
					  DISTPTS *dl)
{
	/* see, lw_dist2d_seg_seg */
	double	s_top, s_bot, s;
	double	r_top, r_bot, r;

	/* A and B are the same point */
	if (A->x == B->x && A->y == B->y)
		return __geom_dist2d_pt_seg(A, C, D, dl);
	/* C and D are the same point */
	if (C->x == D->x && C->y == D->y)
		return __geom_dist2d_pt_seg(D, A, B, dl);

	/* AB and CD are line segments
	 * from comp.graphics.algo
	 *
	 * Solving the above for r and s yields
	 *           (Ay-Cy)(Dx-Cx)-(Ax-Cx)(Dy-Cy)
	 *      r = ----------------------------- (eqn 1)
	 *           (Bx-Ax)(Dy-Cy)-(By-Ay)(Dx-Cx)
	 *
	 *           (Ay-Cy)(Bx-Ax)-(Ax-Cx)(By-Ay)
	 *      s = ----------------------------- (eqn 2)
	 *           (Bx-Ax)(Dy-Cy)-(By-Ay)(Dx-Cx)
	 * Let P be the position vector of the intersection point, then
	 *     P=A+r(B-A) or
	 *     Px=Ax+r(Bx-Ax)
	 *     Py=Ay+r(By-Ay)
	 *
	 * By examining the values of r & s, you can also determine
	 * some other limiting conditions:
	 * If 0<=r<=1 & 0<=s<=1, intersection exists
	 * r<0 or r>1 or s<0 or s>1 line segments do not intersect
	 * If the denominator in eqn 1 is zero, AB & CD are parallel
	 * If the numerator in eqn 1 is also zero, AB & CD are collinear.
	 */
	r_top = (A->y - C->y) * (D->x - C->x) - (A->x - C->x) * (D->y - C->y);
	r_bot = (B->x - A->x) * (D->y - C->y) - (B->y - A->y) * (D->x - C->x);

	s_top = (A->y - C->y) * (B->x - A->x) - (A->x - C->x) * (B->y - A->y);
	s_bot = (B->x - A->x) * (D->y - C->y) - (B->y - A->y) * (D->x - C->x);

	if (r_bot == 0 || s_bot == 0)
	{
		if (__geom_dist2d_pt_seg(A, C, D, dl) &&
			__geom_dist2d_pt_seg(B, C, D, dl))
		{
			dl->twisted *= -1;	/* the order was changed */
			return (__geom_dist2d_pt_seg(C, A, B, dl) &&
					__geom_dist2d_pt_seg(D, A, D, dl));
		}
		return false;
	}

	s = s_top / s_bot;
	r = r_top / r_bot;
	if ((r < 0) || (r > 1) || (s < 0) || (s > 1))
	{
		if (__geom_dist2d_pt_seg(A, C, D, dl) &&
			__geom_dist2d_pt_seg(B, C, D, dl))
		{
			dl->twisted *= -1;	/* the order was changed */
			return (__geom_dist2d_pt_seg(C, A, B, dl) &&
					__geom_dist2d_pt_seg(D, A, B, dl));
		}
		return false;
	}
	else
	{
		/* If there is intersection we identify the intersection point */
		POINT2D		P;

		if ((A->x == C->x && A->y == C->y) ||
			(A->x == D->x && A->y == D->y))
		{
			P.x = A->x;
			P.y = A->y;
		}
		else if ((B->x == C->x && B->y == C->y) ||
				 (B->x == D->x && B->y == D->y))
		{
			P.x = B->x;
			P.y = B->y;
		}
		else
		{
			P.x = A->x + r * (B->x - A->x);
			P.y = A->y + r * (B->y - A->y);
		}
		dl->distance = 0.0;
		dl->p1 = P;
		dl->p2 = P;
	}
	return true;
}

STATIC_FUNCTION(double)
__geom_arc_center(const POINT2D *p1,
				  const POINT2D *p2,
				  const POINT2D *p3,
				  POINT2D *result)
{
	/* see, lw_arc_center */
	POINT2D		c;
	double		dx21, dy21, dx31, dy31, h21, h31, d;

	c.x = c.y = 0.0;

	/* closed circle? */
	if (FP_EQUALS(p1->x, p3->x) && FP_EQUALS(p1->y, p3->y))
	{
		c.x = p1->x + (p2->x - p1->x) / 2.0;
		c.y = p1->y + (p2->y - p1->y) / 2.0;
		*result = c;
		return hypot(c.x - p1->x, c.y - p1->y);
    }

	/*
	 * Using cartesian eguations from the page
	 * https://en.wikipedia.org/wiki/Circumscribed_circle
	 */
	dx21 = p2->x - p1->x;
	dy21 = p2->y - p1->y;
	dx31 = p3->x - p1->x;
	dy31 = p3->y - p1->y;

	h21 = pow(dx21, 2.0) + pow(dy21, 2.0);
	h31 = pow(dx31, 2.0) + pow(dy31, 2.0);

	 /*
	  * 2 * |Cross product|, d<0 means clockwise
	  * and d>0 counterclockwise sweeping angle
	  */
	d = 2 * (dx21 * dy31 - dx31 * dy21);

	/* Check colinearity, |Cross product| = 0 */
	if (fabs(d) < FP_TOLERANCE)
		return -1.0;

	/* Calculate centroid coordinates and radius */
	c.x = p1->x + (h21 * dy31 - h31 * dy21) / d;
	c.y = p1->y - (h21 * dx31 - h31 * dx21) / d;
	*result = c;
	return hypot(c.x - p1->x, c.y - p1->y);
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_pt_arc(const POINT2D *P,
					 const POINT2D *A1,
					 const POINT2D *A2,
					 const POINT2D *A3,
					 DISTPTS *dl)
{
	/* see, lw_dist2d_pt_arc */
	POINT2D		C;	/* center of circle defined by arc A */
	POINT2D		X;	/* point circle(A) where line from C to P crosses */
	double		radius_A, d;

	/* What if the arc is a point? */
	if (A1->x == A2->x && A2->x == A3->x &&
		A1->y == A2->y && A2->y == A3->y )
		return __geom_dist2d_pt_pt(P, A1, dl);

	/* Calculate centers and radii of circles. */
	radius_A = __geom_arc_center(A1, A2, A3, &C);

	/* This "arc" is actually a line (A2 is colinear with A1,A3) */
	if (radius_A < 0.0)
		return __geom_dist2d_pt_seg(P, A1, A3, dl);

	/* Distance from point to center */
	d = hypot(C.x - P->x, C.y - P->y);

	/* P is the center of the circle */
	if (FP_EQUALS(d, 0.0))
	{
		dl->distance = radius_A;
		dl->p1 = *A1;
		dl->p2 = *P;
		return true;
	}

	/* X is the point on the circle where the line from P to C crosses */
	X.x = C.x + (P->x - C.x) * radius_A / d;
	X.y = C.y + (P->y - C.y) * radius_A / d;

	/* Is crossing point inside the arc? Or arc is actually circle? */
	if ((FP_EQUALS(A1->x, A3->x) &&
		 FP_EQUALS(A1->y, A3->y)) || __geom_pt_in_arc(&X, A1, A2, A3))
	{
		__geom_dist2d_pt_pt(P, &X, dl);
	}
	else
	{
		/* Distance is the minimum of the distances to the arc end points */
		__geom_dist2d_pt_pt(A1, P, dl);
		__geom_dist2d_pt_pt(A3, P, dl);
	}
	return true;
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_seg_arc(const POINT2D *A1,
					  const POINT2D *A2,
					  const POINT2D *B1,
					  const POINT2D *B2,
					  const POINT2D *B3,
					  DISTPTS *dl)
{
	/* see lw_dist2d_seg_arc */
	POINT2D		C;			/* center of arc circle */
	POINT2D		D;			/* point on A closest to C */
	double		radius_C;	/* radius of arc circle */
	double		dist_C_D;	/* distance from C to D */
	DISTPTS		dltemp;
	cl_bool		pt_in_arc;
	cl_bool		pt_in_seg;

	/* What if the "arc" is a point? */
	if (B1->x == B2->x && B1->y == B2->y &&
		B2->x == B3->x && B2->y == B3->y)
		return __geom_dist2d_pt_seg(B1, A1, A2, dl);

	/* Calculate center and radius of the circle. */
	radius_C = __geom_arc_center(B1, B2, B3, &C);

	/* This "arc" is actually a line (B2 is collinear with B1,B3) */
	if (radius_C < 0.0)
		return __geom_dist2d_seg_seg(A1, A2, B1, B3, dl);

	/* Calculate distance between the line and circle center */
	memset(&dltemp, 0, sizeof(DISTPTS));
	dltemp.distance = DBL_MAX;
	dltemp.twisted = -1;
	if (!__geom_dist2d_pt_seg(&C, A1, A2, &dltemp))
		return false;
	D = dltemp.p1;
	dist_C_D = dltemp.distance;

	if (dist_C_D < radius_C)
	{
		POINT2D	E, F;	/* points of intersection of edge A and circle(B) */
		double	length_A;	/* length of the segment A */
		double	dist_D_EF;	/* distance from D to E or F */

		dist_D_EF = sqrt(radius_C * radius_C - dist_C_D * dist_C_D);
		length_A = hypot(A2->x - A1->x, A2->y - A1->y);

		/* Point of intersection E */
		E.x = D.x - (A2->x - A1->x) * dist_D_EF / length_A;
		E.y = D.y - (A2->y - A1->y) * dist_D_EF / length_A;
		/* Point of intersection F */
		F.x = D.x + (A2->x - A1->x) * dist_D_EF / length_A;
		F.y = D.y + (A2->y - A1->y) * dist_D_EF / length_A;

		/* If E is within A and within B then it's an intersection point */
		pt_in_arc = __geom_pt_in_arc(&E, B1, B2, B3);
		pt_in_seg = __geom_pt_in_seg(&E, A1, A2);
		if (pt_in_arc && pt_in_seg)
		{
			dl->distance = 0.0;
			dl->p1 = E;
			dl->p2 = E;
			return true;
		}

		 /* If F is within A and within B then it's an intersection point */
		pt_in_arc = __geom_pt_in_arc(&F, B1, B2, B3);
		pt_in_seg = __geom_pt_in_seg(&F, A1, A2);
		if (pt_in_arc && pt_in_seg)
		{
			dl->distance = 0.0;
			dl->p1 = F;
			dl->p2 = F;
			return true;
		}
	}
	else if (dist_C_D == radius_C)
	{
		/* Is D contained in both A and B? */
		pt_in_arc = __geom_pt_in_arc(&D, B1, B2, B3);
		pt_in_seg = __geom_pt_in_seg(&D, A1, A2);
		if (pt_in_arc && pt_in_seg)
		{
			dl->distance = 0.0;
			dl->p1 = D;
			dl->p2 = D;
			return true;
		}
	}
	else
	{
		POINT2D		G;	/* Point on circle closest to A */

		G.x = C.x + (D.x - C.x) * radius_C / dist_C_D;
		G.y = C.y + (D.y - C.y) * radius_C / dist_C_D;

		pt_in_arc = __geom_pt_in_arc(&G, B1, B2, B3);
		pt_in_seg = __geom_pt_in_seg(&D, A1, A2);
		if (pt_in_arc && pt_in_seg)
			return __geom_dist2d_pt_pt(&D, &G, dl);
	}

	if (pt_in_arc && !pt_in_seg)
	{
		/* closest point is in the arc, but not in the segment,
		 * so one of the segment end points must be the closest.
		 */
		__geom_dist2d_pt_arc(A1, B1, B2, B3, dl);
		__geom_dist2d_pt_arc(A2, B1, B2, B3, dl);
		return true;
	}

	if (pt_in_seg && !pt_in_arc)
	{
		/* or, one of the arc end points is the closest */
		__geom_dist2d_pt_seg(B1, A1, A2, dl);
		__geom_dist2d_pt_seg(B3, A1, A2, dl);
		return true;
	}
	/* finally, one of the end-point to end-point combos is the closest. */
	__geom_dist2d_pt_pt(A1, B1, dl);
	__geom_dist2d_pt_pt(A1, B3, dl);
	__geom_dist2d_pt_pt(A2, B1, dl);
	__geom_dist2d_pt_pt(A2, B3, dl);
	return true;
}

STATIC_INLINE(double)
distance2d_sqr_pt_pt(const POINT2D *p1,
					 const POINT2D *p2)
{
	double	hside = p2->x - p1->x;
	double	vside = p2->y - p1->y;

	return hside * hside + vside * vside;
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_arc_arc_concentric(const POINT2D *A1,
								 const POINT2D *A2,
								 const POINT2D *A3,
								 double radius_A,
								 const POINT2D *B1,
								 const POINT2D *B2,
								 const POINT2D *B3,
								 double radius_B,
								 const POINT2D *CENTER,
								 DISTPTS *dl)
{
	int			seg_side;
	double		dist_sqr;
	double		shortest_sqr;
	const POINT2D *P1;
	const POINT2D *P2;

	if (radius_A == radius_B)
    {
		/* Check if B1 or B3 are in the same side as A2 in the A1-A3 arc */
		seg_side = __geom_segment_side(A1, A3, A2);
		if (seg_side == __geom_segment_side(A1, A3, B1))
		{
			dl->distance = 0;
			dl->p1 = *B1;
			dl->p2 = *B1;
			return true;
		}
		if (seg_side == __geom_segment_side(A1, A3, B3))
		{
			dl->distance = 0;
			dl->p1 = *B3;
			dl->p2 = *B3;
			return true;
		}
		/* Check if A1 or A3 are in the same side as B2 in the B1-B3 arc */
		seg_side = __geom_segment_side(B1, B3, B2);
		if (seg_side == __geom_segment_side(B1, B3, A1))
		{
			dl->distance = 0;
			dl->p1 = *A1;
			dl->p2 = *A1;
			return true;
		}
		if (seg_side == __geom_segment_side(B1, B3, A3))
		{
			dl->distance = 0;
			dl->p1 = *A3;
			dl->p2 = *A3;
			return true;
		}
	}
	else
	{
		/* Check if any projection of B ends are in A*/
		POINT2D		proj;

		seg_side = __geom_segment_side(A1, A3, A2);
		/* B1 */
        proj.x = CENTER->x + (B1->x - CENTER->x) * radius_A / radius_B;
        proj.y = CENTER->y + (B1->y - CENTER->y) * radius_A / radius_B;
		if (seg_side == __geom_segment_side(A1, A3, &proj))
		{
			dl->distance = fabs(radius_A - radius_B);
			dl->p1 = proj;
			dl->p2 = *B1;
			return true;
		}
		/* B3 */
		proj.x = CENTER->x + (B3->x - CENTER->x) * radius_A / radius_B;
		proj.y = CENTER->y + (B3->y - CENTER->y) * radius_A / radius_B;
		if (seg_side == __geom_segment_side(A1, A3, &proj))
		{
			dl->distance = fabs(radius_A - radius_B);
			dl->p1 = proj;
			dl->p2 = *B3;
			return true;
		}

		/* Now check projections of A in B */
		seg_side = __geom_segment_side(B1, B3, B2);
		/* A1 */
		proj.x = CENTER->x + (A1->x - CENTER->x) * radius_B / radius_A;
		proj.y = CENTER->y + (A1->y - CENTER->y) * radius_B / radius_A;
		if (seg_side == __geom_segment_side(B1, B3, &proj))
		{
			dl->distance = fabs(radius_A - radius_B);
			dl->p1 = proj;
			dl->p2 = *A1;
			return true;
		}

		/* A3 */
		proj.x = CENTER->x + (A3->x - CENTER->x) * radius_B / radius_A;
		proj.y = CENTER->y + (A3->y - CENTER->y) * radius_B / radius_A;
		if (seg_side == __geom_segment_side(B1, B3, &proj))
		{
			dl->distance = fabs(radius_A - radius_B);
			dl->p1 = proj;
			dl->p2 = *A3;
			return true;
		}
	}

	/* check the shortest between the distances of the 4 ends */
	shortest_sqr = dist_sqr = distance2d_sqr_pt_pt(A1, B1);
	P1 = A1;
	P2 = B1;

	dist_sqr = distance2d_sqr_pt_pt(A1, B3);
	if (dist_sqr < shortest_sqr)
	{
		shortest_sqr = dist_sqr;
		P1 = A1;
		P2 = B3;
	}

	dist_sqr = distance2d_sqr_pt_pt(A3, B1);
	if (dist_sqr < shortest_sqr)
	{
		shortest_sqr = dist_sqr;
		P1 = A3;
		P2 = B1;
	}

	dist_sqr = distance2d_sqr_pt_pt(A3, B3);
	if (dist_sqr < shortest_sqr)
	{
		shortest_sqr = dist_sqr;
		P1 = A3;
		P2 = B3;
	}
	dl->distance = sqrt(shortest_sqr);
	dl->p1 = *P1;
	dl->p2 = *P2;

	return true;
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_arc_arc(const POINT2D *A1,
					  const POINT2D *A2,
					  const POINT2D *A3,
					  const POINT2D *B1,
					  const POINT2D *B2,
					  const POINT2D *B3,
					  DISTPTS *dl)
{
	/* lw_dist2d_arc_arc */
	POINT2D		CA, CB;		/* Center points of arcs A and B */
	double		radius_A;	/* Radii of arcs A and B */
	double		radius_B;
	double		d;
	cl_bool		pt_in_arc_A;
	cl_bool		pt_in_arc_B;

	/* What if one or both of our "arcs" is actually a point? */
	if (B1->x == B2->x && B2->x == B3->x &&
		B1->y == B2->y && B2->y == B3->y)
	{
		if (A1->x == A2->x && A2->x == A3->x &&
			A1->y == A2->y && A2->y == A3->y)
			return __geom_dist2d_pt_pt(B1, A1, dl);
		else
			return __geom_dist2d_pt_arc(B1, A1, A2, A3, dl);
	}
	else if (A1->x == A2->x && A2->x == A3->x &&
			 A1->y == A2->y && A2->y == A3->y)
		return __geom_dist2d_pt_arc(A1, B1, B2, B3, dl);

	/*c alculate centers and radii of circles. */
	radius_A = __geom_arc_center(A1, A2, A3, &CA);
	radius_B = __geom_arc_center(B1, B2, B3, &CB);

	/* two co-linear arcs?!? That's two segments. */
	if (radius_A < 0 && radius_B < 0)
		return __geom_dist2d_seg_seg(A1, A3, B1, B3, dl);
	/* A is co-linear, delegate to lw_dist_seg_arc here. */
	if (radius_A < 0)
		return __geom_dist2d_seg_arc(A1, A3, B1, B2, B3, dl);
	/* B is co-linear, delegate to lw_dist_seg_arc here. */
	if (radius_B < 0)
		return __geom_dist2d_seg_arc(B1, B3, A1, A2, A3, dl);
	/* center-center distance */
	d = hypot(CA.x - CB.x, CA.y - CB.y);

	/* concentric arcs */
	if (FP_EQUALS(d, 0.0))
		return __geom_dist2d_arc_arc_concentric(A1, A2, A3, radius_A,
												B1, B2, B3, radius_B,
												&CA, dl);
	/* make sure that arc "A" has the bigger radius */
	if (radius_B > radius_A)
	{
		__swap(A1, B1);
		__swap(A2, B2);
		__swap(A3, B3);
		__swap(CA, CB);
		__swap(radius_A, radius_B);
	}

	/* circles touch at a point. Is that point within the arcs? */
	if (d == (radius_A + radius_B))
	{
		POINT2D		D;			/* Mid-point between the centers CA and CB */

		D.x = CA.x + (CB.x - CA.x) * radius_A / d;
		D.y = CA.y + (CB.y - CA.y) * radius_A / d;
		pt_in_arc_A = __geom_pt_in_arc(&D, A1, A2, A3);
		pt_in_arc_B = __geom_pt_in_arc(&D, B1, B2, B3);
		if (pt_in_arc_A && pt_in_arc_B)
		{
			dl->distance = 0.0;
			dl->p1 = D;
			dl->p2 = D;
			return true;
		}
	}
	else if (d > (radius_A + radius_B) ||	/* Disjoint */
			 d < (radius_A - radius_B))		/* Contained */
	{
		/* Points where the line from CA to CB cross their circle bounds */
		POINT2D		XA, XB;

		XA.x = CA.x + (CB.x - CA.x) * radius_A / d;
		XA.y = CA.y + (CB.y - CA.y) * radius_A / d;
		XB.x = CB.x + (CA.x - CB.x) * radius_B / d;
		XB.y = CB.y + (CA.y - CB.y) * radius_B / d;

		pt_in_arc_A = __geom_pt_in_arc(&XA, A1, A2, A3);
		pt_in_arc_B = __geom_pt_in_arc(&XB, B1, B2, B3);
		if (pt_in_arc_A && pt_in_arc_B)
			return __geom_dist2d_pt_pt(&XA, &XB, dl);
	}
	else if (d < (radius_A + radius_B))		/* crosses at two points */
	{
		POINT2D		D, E, F;
		double		a = (radius_A * radius_A -
						 radius_B * radius_B + d * d) / (2 * d);
		double		h = sqrt(radius_A * radius_A - a * a);

		/* Location of D */
		D.x = CA.x + (CB.x - CA.x) * a / d;
		D.y = CA.y + (CB.y - CA.y) * a / d;

		/* Start from D and project h units perpendicular to CA-D to get E */
		E.x = D.x + (D.y - CA.y) * h / a;
		E.y = D.y + (D.x - CA.x) * h / a;

		/* Crossing point E contained in arcs? */
		pt_in_arc_A = __geom_pt_in_arc(&E, A1, A2, A3);
		pt_in_arc_B = __geom_pt_in_arc(&E, B1, B2, B3);
		if (pt_in_arc_A && pt_in_arc_B)
		{
			dl->distance = 0.0;
			dl->p1 = E;
			dl->p2 = E;
			return true;
		}

		/* Start from D and project h units perpendicular to CA-D to get F */
		F.x = D.x - (D.y - CA.y) * h / a;
		F.y = D.y - (D.x - CA.x) * h / a;

		/* Crossing point F contained in arcs? */
		pt_in_arc_A = __geom_pt_in_arc(&F, A1, A2, A3);
		pt_in_arc_B = __geom_pt_in_arc(&F, B1, B2, B3);
		if (pt_in_arc_A && pt_in_arc_B)
		{
			dl->distance = 0.0;
			dl->p1 = F;
			dl->p2 = F;
			return true;
		}
	}
	else
	{
		STROM_ELOG(dl->kcxt, "arcs neither touch, intersect nor disjoint");
		return false;
	}

	if (pt_in_arc_A && !pt_in_arc_B)
	{
		/*
		 * closest point is in the arc A, but not in the arc B,
		 * so one of the B end points must be the closest.
		 */
		__geom_dist2d_pt_arc(B1, A1, A2, A3, dl);
		__geom_dist2d_pt_arc(B3, A1, A2, A3, dl);
	}
	else if (!pt_in_arc_A && pt_in_arc_B)
	{
		/*
		 * closest point is in the arc B, but not in the arc A,
		 * so one of the A end points must be the closest.
		 */
		__geom_dist2d_pt_arc(A1, B1, B2, B3, dl);
		__geom_dist2d_pt_arc(A3, B1, B2, B3, dl);
	}
	else
	{
		/* finally, one of the end-point to end-point combos is the closest. */
		__geom_dist2d_pt_pt(A1, B1, dl);
        __geom_dist2d_pt_pt(A1, B3, dl);
        __geom_dist2d_pt_pt(A3, B1, dl);
        __geom_dist2d_pt_pt(A3, B3, dl);
	}
	return true;
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_pt_ptarray(const POINT2D *pt,
						 const pg_geometry_t *geom,
						 DISTPTS *dl)
{
	size_t		unitsz = sizeof(double) * GEOM_FLAGS_NDIMS(geom->flags);
	const char *rawdata = geom->rawdata;
	POINT2D		start, end;

	if (geom->nitems == 0)
		return false;
	rawdata = __loadPoint2d(&start, rawdata, unitsz);

	if (!__geom_dist2d_pt_pt(pt, &start, dl))
		return false;
	for (int i = 1; i < geom->nitems; i++)
	{
		rawdata = __loadPoint2d(&end, rawdata, unitsz);

		if (!__geom_dist2d_pt_seg(pt, &start, &end, dl))
			return false;
		start = end;
	}
	return true;
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_ptarray_ptarray(const pg_geometry_t *geom1,
							  const pg_geometry_t *geom2,
							  DISTPTS *dl)
{
	/* see lw_dist2d_ptarray_ptarray */
	cl_uint		unitsz1 = sizeof(double) * GEOM_FLAGS_NDIMS(geom1->flags);
	cl_uint		unitsz2 = sizeof(double) * GEOM_FLAGS_NDIMS(geom2->flags);
	const char *rawdata1;
	const char *rawdata2;
	POINT2D		start, end;
	POINT2D		start2, end2;

	rawdata1 = __loadPoint2d(&start, geom1->rawdata, unitsz1);
	for (int i=1; i < geom1->nitems; i++, start=end)
	{
		rawdata1 = __loadPoint2d(&end, rawdata1, unitsz1);
		rawdata2 = __loadPoint2d(&start2, geom2->rawdata, unitsz2);
		for (int j=1; j < geom2->nitems; j++, start2=end2)
		{
			rawdata2 = __loadPoint2d(&end2, rawdata2, unitsz2);
			__geom_dist2d_seg_seg(&start, &end, &start2, &end2, dl);
		}
	}
	return true;
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_pt_ptarrayarc(const POINT2D *pt,
							const pg_geometry_t *geom,
							DISTPTS *dl)
{
	POINT2D		A1, A2, A3;
	size_t		unitsz = sizeof(double) * GEOM_FLAGS_NDIMS(geom->flags);
	const char *rawdata;

	if (geom->nitems % 2 == 0 || geom->nitems < 3)
		return false;
	rawdata = __loadPoint2d(&A1, geom->rawdata, unitsz);
	if (!__geom_dist2d_pt_pt(pt, &A1, dl))
		return false;
	for (int i=1; i < geom->nitems; i+=2)
	{
		rawdata = __loadPoint2d(&A2, rawdata, unitsz);
		rawdata = __loadPoint2d(&A3, rawdata, unitsz);
		if (!__geom_dist2d_pt_arc(pt, &A1, &A2, &A3, dl))
			return false;
		A1 = A3;
	}
	return true;
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_ptarray_ptarrayarc(const pg_geometry_t *geom,
								 const pg_geometry_t *garc,
								 DISTPTS *dl)
{
	POINT2D		A1, A2;
	POINT2D		B1, B2, B3;
	cl_uint		unitsz_a = sizeof(double) * GEOM_FLAGS_NDIMS(geom->flags);
	cl_uint		unitsz_b = sizeof(double) * GEOM_FLAGS_NDIMS(garc->flags);
	const char *rawdata_a;
	const char *rawdata_b;

	if (garc->nitems % 2 == 0 || garc->nitems < 3)
		return false;

	rawdata_a = __loadPoint2d(&A1, geom->rawdata, unitsz_a);
	for (int t = 1; t < geom->nitems; t++, A1=A2)
	{
		rawdata_a = __loadPoint2d(&A2, rawdata_a, unitsz_a);
		rawdata_b = __loadPoint2d(&B1, garc->rawdata, unitsz_b);
		for (int u = 1; u < garc->nitems; u+=2, B1=B3)
		{
			rawdata_b = __loadPoint2d(&B2, rawdata_b, unitsz_b);
			rawdata_b = __loadPoint2d(&B3, rawdata_b, unitsz_b);
			__geom_dist2d_seg_arc(&A1, &A2, &B1, &B2, &B3, dl);
		}
	}
	return true;
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_ptarrayarc_ptarrayarc(const pg_geometry_t *geom1,
									const pg_geometry_t *geom2,
									DISTPTS *dl)
{
	/* see lw_dist2d_ptarrayarc_ptarrayarc */
	POINT2D		A1, A2, A3;
	POINT2D		B1, B2, B3;
	cl_uint		unitsz1 = sizeof(double) * GEOM_FLAGS_NDIMS(geom1->flags);
	cl_uint		unitsz2 = sizeof(double) * GEOM_FLAGS_NDIMS(geom2->flags);
	const char *rawdata1;
	const char *rawdata2;
	int			twist = dl->twisted;

	rawdata1 = __loadPoint2d(&A1, geom1->rawdata, unitsz1);
	for (int t = 1; t < geom1->nitems; t += 2, A1 = A3)
	{
		rawdata1 = __loadPoint2d(&A2, rawdata1, unitsz1);
		rawdata1 = __loadPoint2d(&A3, rawdata1, unitsz1);

		rawdata2 = __loadPoint2d(&B1, geom2->rawdata, unitsz2);
		for (int u = 1; u < geom2->nitems; u += 2, B1 = B3)
		{
			rawdata2 = __loadPoint2d(&B2, rawdata2, unitsz2);
			rawdata2 = __loadPoint2d(&B3, rawdata2, unitsz2);
			dl->twisted = twist;
			if (!__geom_dist2d_arc_arc(&A1, &A2, &A3, &B1, &B2, &B3, dl))
				return false;
		}
	}
	return true;
}

/* forward declaration */
STATIC_FUNCTION(cl_bool)
geom_dist2d_recursive(const pg_geometry_t *geom1,
					  const pg_geometry_t *geom2,
					  DISTPTS *dl);

STATIC_FUNCTION(cl_bool)
geom_dist2d_point_point(const pg_geometry_t *geom1,
						const pg_geometry_t *geom2,
						DISTPTS *dl)
{
	/* see, lw_dist2d_point_point() */
	POINT2D		p1, p2;

	assert(geom1->type == GEOM_POINTTYPE &&
		   geom2->type == GEOM_POINTTYPE);
	__loadPoint2d(&p1, geom1->rawdata, 0);
	__loadPoint2d(&p2, geom2->rawdata, 0);
	return __geom_dist2d_pt_pt(&p1, &p2, dl);
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_point_line(const pg_geometry_t *geom1,
                       const pg_geometry_t *geom2,
                       DISTPTS *dl)
{
	/* see, lw_dist2d_point_line */
	POINT2D		pt;

	assert(geom1->type == GEOM_POINTTYPE &&
		   geom2->type == GEOM_LINETYPE);
	__loadPoint2d(&pt, geom1->rawdata, 0);
	return __geom_dist2d_pt_ptarray(&pt, geom2, dl);
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_point_tri(const pg_geometry_t *geom1,
					  const pg_geometry_t *geom2,
					  DISTPTS *dl)
{
	/* see, lw_dist2d_point_tri */
	POINT2D		pt;
	int			status;

	assert(geom1->type == GEOM_POINTTYPE &&
		   geom2->type == GEOM_TRIANGLETYPE);
	__loadPoint2d(&pt, geom1->rawdata, 0);
	status = __geom_contains_point(geom2, &pt, dl);
	if (status == PT_ERROR)
		return false;
	else if (status != PT_OUTSIDE)
	{
		dl->distance = 0.0;
		dl->p1 = pt;
		dl->p2 = pt;
		return true;
	}
	assert(status == PT_OUTSIDE);
	return __geom_dist2d_pt_ptarray(&pt, geom2, dl);
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_point_poly(const pg_geometry_t *geom1,
					   const pg_geometry_t *geom2,
					   DISTPTS *dl)
{
	/* see, lw_dist2d_point_poly */
	POINT2D		pt;
	const char *pos = NULL;

	assert(geom1->type == GEOM_POINTTYPE &&
		   geom2->type == GEOM_POLYGONTYPE);
	__loadPoint2d(&pt, geom1->rawdata, 0);
	for (int i=0; i < geom2->nitems; i++)
	{
		pg_geometry_t __geom;
		int		status;

		pos = __load_sub_geometry(&__geom, geom2, pos, i);
		status = __geom_contains_point(&__geom, &pt, dl);
		if (status == PT_ERROR)
			return false;
		if (i == 0)
		{
			/* Return distance to outer ring if not inside it */
			if (status == PT_OUTSIDE)
				return __geom_dist2d_pt_ptarray(&pt, &__geom, dl);
		}
		else
		{
			 /*
			  * Inside the outer ring.
			  * Scan though each of the inner rings looking to
			  * see if its inside.  If not, distance==0.
			  * Otherwise, distance = pt to ring distance
			  */
			if (status == PT_BOUNDARY || status == PT_INSIDE)
				return __geom_dist2d_pt_ptarray(&pt, &__geom, dl);
		}
	}
	/* It is inside of the polygon  */
	dl->distance = 0.0;
	dl->p1 = pt;
	dl->p2 = pt;
	return true;
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_point_circstring(const pg_geometry_t *geom1,
							 const pg_geometry_t *geom2,
							 DISTPTS *dl)
{
	/* see, lw_dist2d_point_circstring() */
	POINT2D		pt;

	assert(geom1->type == GEOM_POINTTYPE &&
		   geom2->type == GEOM_CIRCSTRINGTYPE);
	__loadPoint2d(&pt, geom1->rawdata, 0);
	return __geom_dist2d_pt_ptarrayarc(&pt, geom2, dl);
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_point_curvepoly(const pg_geometry_t *geom1,
							const pg_geometry_t *geom2,
							DISTPTS *dl)
{
	/* see, lw_dist2d_point_curvepoly */
	POINT2D		pt;
	const char *pos = NULL;

	assert(geom1->type == GEOM_POINTTYPE &&
		   geom2->type == GEOM_CURVEPOLYTYPE);
	__loadPoint2d(&pt, geom1->rawdata, 0);
	for (int i=0; i < geom2->nitems; i++)
	{
		pg_geometry_t __geom;
		int		status;

		pos = __load_sub_geometry(&__geom, geom2, pos, i);

		status = __geom_contains_point(&__geom, &pt, dl);
		if (status == PT_ERROR)
			return false;
		if (i == 0)
		{
			if (status == PT_OUTSIDE)
				return geom_dist2d_recursive(geom1, &__geom, dl);
		}
		else
		{
			if (status == PT_INSIDE)
				return geom_dist2d_recursive(geom1, &__geom, dl);
		}
	}
	/* Is inside the polygon */
	dl->distance = 0.0;
	dl->p1 = pt;
	dl->p2 = pt;
	return true;
}

STATIC_INLINE(cl_bool)
geom_dist2d_line_line(const pg_geometry_t *geom1,
					  const pg_geometry_t *geom2,
					  DISTPTS *dl)
{
	/* see lw_dist2d_line_line */
	assert(geom1->type == GEOM_LINETYPE &&
		   geom2->type == GEOM_LINETYPE);
	return __geom_dist2d_ptarray_ptarray(geom1, geom2, dl);
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_line_tri(const pg_geometry_t *geom1,
					 const pg_geometry_t *geom2,
					 DISTPTS *dl)
{
	/* see lw_dist2d_line_tri */
	POINT2D		pt;

	assert(geom1->type == GEOM_LINETYPE &&
		   geom2->type == GEOM_TRIANGLETYPE);
	/* XXX why only point-0? */
	__loadPoint2d(&pt, geom1->rawdata, 0);
	if (__geom_contains_point(geom2, &pt, dl))
	{
		dl->distance = 0.0;
		dl->p1 = pt;
		dl->p2 = pt;
		return true;
	}
	return __geom_dist2d_ptarray_ptarray(geom1, geom2, dl);
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_line_poly(const pg_geometry_t *geom1,
					  const pg_geometry_t *geom2,
					  DISTPTS *dl)
{
	/* see, lw_dist2d_line_poly */
	const char *pos = NULL;
	POINT2D		pt0;
	cl_bool		meet_inside = false;

	assert((geom1->type == GEOM_LINETYPE ||
			geom1->type == GEOM_CIRCSTRINGTYPE) &&
		   geom2->type == GEOM_POLYGONTYPE);
	__loadPoint2d(&pt0, geom1->rawdata, 0);
	for (int i=0; i < geom2->nitems; i++)
	{
		pg_geometry_t __geom;
		int		status;

		pos = __load_sub_geometry(&__geom, geom2, pos, i);
		if (i == 0)
		{
			/* Line has a point outside of the polygon.
			 * Check distance to outer ring only.
			 */
			status = __geom_contains_point(&__geom, &pt0, dl);
			if (status == PT_ERROR)
				return false;
			if (status == PT_OUTSIDE)
				return __geom_dist2d_ptarray_ptarray(geom1, &__geom, dl);
		}
		else if (!meet_inside)
		{
			status = __geom_contains_point(&__geom, &pt0, dl);
			if (status == PT_ERROR)
				return false;
			if (status != PT_OUTSIDE)
				meet_inside = true;
		}
	}

	if (!meet_inside)
	{
		dl->distance = 0.0;
		dl->p1 = pt0;
		dl->p2 = pt0;
	}
	return true;
}

STATIC_INLINE(cl_bool)
geom_dist2d_line_circstring(const pg_geometry_t *geom1,
							const pg_geometry_t *geom2,
							DISTPTS *dl)
{
	/* see, lw_dist2d_line_circstring */
	assert(geom1->type == GEOM_LINETYPE &&
		   geom2->type == GEOM_CIRCSTRINGTYPE);
	return __geom_dist2d_ptarray_ptarrayarc(geom1, geom2, dl);
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_line_curvepoly(const pg_geometry_t *geom1,
						   const pg_geometry_t *geom2,
						   DISTPTS *dl)
{
	/* see, lw_dist2d_line_curvepoly */
	const char *pos = NULL;
	POINT2D		pt0;
	cl_bool		meet_inside = false;

	/* note that geom_dist2d_circstring_curvepoly() may call this function */
	assert((geom1->type == GEOM_LINETYPE ||
			geom1->type == GEOM_CIRCSTRINGTYPE) &&
		   geom2->type == GEOM_CURVEPOLYTYPE);

	__loadPoint2d(&pt0, geom1->rawdata, 0);
	for (int i=0; i < geom2->nitems; i++)
	{
		pg_geometry_t __geom;
		int		status;

		pos = __load_sub_geometry(&__geom, geom2, pos, i);
		if (i == 0)
		{
			status = __geom_contains_point(&__geom, &pt0, dl);
			if (status == PT_ERROR)
				return false;
			if (status == PT_OUTSIDE)
				return geom_dist2d_recursive(geom1, &__geom, dl);
		}
		else
		{
			if (!geom_dist2d_recursive(geom1, &__geom, dl))
				return false;
			if (!meet_inside)
			{
				status = __geom_contains_point(&__geom, &pt0, dl);
				if (status == PT_ERROR)
					return false;
				if (status != PT_OUTSIDE)
					meet_inside = true;
			}
		}
	}

	if (!meet_inside)
	{
		dl->distance = 0.0;
		dl->p1 = pt0;
		dl->p2 = pt0;
	}
	return true;
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_tri_tri(const pg_geometry_t *geom1,
					const pg_geometry_t *geom2,
					DISTPTS *dl)
{
	/* see lw_dist2d_tri_tri */
	POINT2D		pt;
	int			status;

	assert(geom1->type == GEOM_TRIANGLETYPE &&
		   geom2->type == GEOM_TRIANGLETYPE);

	__loadPoint2d(&pt, geom2->rawdata, 0);
	status = __geom_contains_point(geom1, &pt, dl);
	if (status == PT_ERROR)
		return false;
	else if (status != PT_OUTSIDE)
	{
		dl->distance = 0.0;
		dl->p1 = pt;
		dl->p2 = pt;
		return true;
	}

	__loadPoint2d(&pt, geom1->rawdata, 0);
	status = __geom_contains_point(geom2, &pt, dl);
	if (status == PT_ERROR)
		return false;
	else if (status != PT_OUTSIDE)
	{
		dl->distance = 0.0;
		dl->p1 = pt;
		dl->p2 = pt;
		return true;
	}
	return __geom_dist2d_ptarray_ptarray(geom1, geom2, dl);
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_tri_poly(const pg_geometry_t *geom1,
					 const pg_geometry_t *geom2,
					 DISTPTS *dl)
{
	/* lw_dist2d_tri_poly */
	const char *pos = NULL;
	POINT2D		pt;
	cl_bool		meet_inside = false;

	assert(geom1->type == GEOM_TRIANGLETYPE &&
		   geom2->type == GEOM_POLYGONTYPE);
	__loadPoint2d(&pt, geom1->rawdata, 0);
	for (int i=0; i < geom2->nitems; i++)
	{
		pg_geometry_t __geom;
		int		status;

		pos = __load_sub_geometry(&__geom, geom2, pos, i);
		if (i == 0)
		{
			status = __geom_contains_point(&__geom, &pt, dl);
			if (status == PT_ERROR)
				return false;
			if (status == PT_OUTSIDE)
			{
				POINT2D		pt2;

				if (!__geom_dist2d_ptarray_ptarray(geom1, &__geom, dl))
					return false;
				__loadPoint2d(&pt2, __geom.rawdata, 0);
				status = __geom_contains_point(geom1, &pt2, dl);
				if (status == PT_ERROR)
					return false;
				if (status != PT_OUTSIDE)
				{
					dl->distance = 0.0;
					dl->p1 = pt2;
					dl->p2 = pt2;
					return true;
				}
			}
		}
		else
		{
			if (!__geom_dist2d_ptarray_ptarray(geom1, &__geom, dl))
				return false;
			if (!meet_inside)
			{
				status = __geom_contains_point(&__geom, &pt, dl);
				if (status == PT_ERROR)
					return false;
				if (status != PT_OUTSIDE)
					meet_inside = true;
			}
		}
	}

	if (!meet_inside)
	{
		dl->distance = 0.0;
		dl->p1 = pt;
		dl->p2 = pt;
	}
	return true;
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_tri_circstring(const pg_geometry_t *geom1,
						   const pg_geometry_t *geom2,
						   DISTPTS *dl)
{
	/* see lw_dist2d_tri_circstring */
	POINT2D		pt;
	int			status;

	assert(geom1->type == GEOM_TRIANGLETYPE &&
		   geom2->type == GEOM_CIRCSTRINGTYPE);

	__loadPoint2d(&pt, geom2->rawdata, 0);
	status = __geom_contains_point(geom1, &pt, dl);
	if (status == PT_ERROR)
		return false;
	if (status != PT_OUTSIDE)
	{
		dl->distance = 0.0;
		dl->p1 = pt;
		dl->p2 = pt;
		return true;
	}
	return __geom_dist2d_ptarray_ptarrayarc(geom1, geom2, dl);
}

STATIC_INLINE(cl_bool)
__geom_curvering_getfirstpoint2d(POINT2D *pt,
								 const pg_geometry_t *geom,
								 DISTPTS *dl)
{
	/* see lw_curvering_getfirstpoint2d_cp */
	if (geom->type == GEOM_LINETYPE ||
		geom->type == GEOM_CIRCSTRINGTYPE)
	{
		memcpy(pt, &geom->rawdata, sizeof(POINT2D));
		return true;
	}
	else if (geom->type == GEOM_COMPOUNDTYPE)
	{
		//XXX compound has inline types, right assumption?
		const char *dataptr
			= (geom->rawdata + LONGALIGN(sizeof(cl_uint) * geom->nitems));
		__loadPoint2d(pt, dataptr, 0);
		return true;
	}
	return false;
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_tri_curvepoly(const pg_geometry_t *geom1,
						  const pg_geometry_t *geom2,
						  DISTPTS *dl)
{
	/* see lw_dist2d_tri_curvepoly */
	const char *pos = NULL;
	POINT2D		pt;
	cl_bool		meet_inside = false;

	assert(geom1->type == GEOM_TRIANGLETYPE &&
		   geom2->type == GEOM_CURVEPOLYTYPE);

	__loadPoint2d(&pt, geom1->rawdata, 0);
	for (int i=0; i < geom2->nitems; i++)
	{
		pg_geometry_t __geom;
		cl_int		status;

		pos = __load_sub_geometry(&__geom, geom2, pos, i);
		if (i == 0)
		{
			status = __geom_contains_point(&__geom, &pt, dl);
			if (status == PT_ERROR)
				return false;
			if (status == PT_OUTSIDE)
			{
				POINT2D		pt2;

				if (!geom_dist2d_recursive(geom1, &__geom, dl))
					return false;
				if (!__geom_curvering_getfirstpoint2d(&pt2, &__geom, dl))
					return false;
				/* maybe poly is inside triangle? */
				status = __geom_contains_point(geom1, &pt2, dl);
				if (status == PT_ERROR)
					return false;
				if (status != PT_OUTSIDE)
				{
					dl->distance = 0.0;
					dl->p1 = pt;
					dl->p2 = pt;
					return true;
				}
			}
		}
		else
		{
			if (!geom_dist2d_recursive(geom1, &__geom, dl))
				return false;
			if (!meet_inside)
			{
				status = __geom_contains_point(&__geom, &pt, dl);
				if (status == PT_ERROR)
					return false;
				if (status != PT_OUTSIDE)
					meet_inside = true;
			}
		}
	}

	if (!meet_inside)
	{
		dl->distance = 0.0;
		dl->p1 = pt;
		dl->p2 = pt;
	}
	return true;
}

STATIC_INLINE(cl_bool)
geom_dist2d_circstring_poly(const pg_geometry_t *geom1,
							const pg_geometry_t *geom2,
							DISTPTS *dl)
{
	/* see, lw_dist2d_circstring_poly() */
	return geom_dist2d_line_poly(geom1, geom2, dl);
}

STATIC_INLINE(cl_bool)
geom_dist2d_circstring_circstring(const pg_geometry_t *geom1,
								  const pg_geometry_t *geom2,
								  DISTPTS *dl)
{
	/* see, lw_dist2d_circstring_circstring */
	assert(geom1->type == GEOM_CIRCSTRINGTYPE &&
		   geom2->type == GEOM_CIRCSTRINGTYPE);
	return __geom_dist2d_ptarrayarc_ptarrayarc(geom1, geom2, dl);
}

STATIC_INLINE(cl_bool)
geom_dist2d_circstring_curvepoly(const pg_geometry_t *geom1,
								 const pg_geometry_t *geom2,
								 DISTPTS *dl)
{
	/* see, lw_dist2d_circstring_curvepoly */
	assert(geom1->type == GEOM_CIRCSTRINGTYPE &&
		   geom2->type == GEOM_CURVEPOLYTYPE);
	return geom_dist2d_line_curvepoly(geom1, geom2, dl);
}

STATIC_FUNCTION(cl_bool)
__geom_dist2d_xpoly_xpoly(const pg_geometry_t *geom1,
						  const pg_geometry_t *geom2,
						  DISTPTS *dl)
{
	/* see, lw_dist2d_poly_poly */
	pg_geometry_t __geom1;
	pg_geometry_t __geom2;
	pg_geometry_t __gtemp;
	const char *pos = NULL;
	POINT2D		pt;
	int			status;

 	assert((geom1->type == GEOM_POLYGONTYPE ||
			geom1->type == GEOM_CURVEPOLYTYPE) &&
		   (geom2->type == GEOM_POLYGONTYPE ||
			geom2->type == GEOM_CURVEPOLYTYPE));
	__load_sub_geometry(&__geom1, geom1, NULL, 0);
	__load_sub_geometry(&__geom2, geom2, NULL, 0);

    /* 2. check if poly1 has first point outside poly2 and vice versa,
	 * if so, just check outer rings here it would be possible to handle
	 * the information about which one is inside which one and only search
	 * for the smaller ones in the bigger ones holes.
	 */
	__loadPoint2d(&pt, __geom1.rawdata, 0);
	status = __geom_contains_point(&__geom2, &pt, dl);
	if (status == PT_ERROR)
		return false;
	if (status == PT_OUTSIDE)
	{
		__loadPoint2d(&pt, __geom2.rawdata, 0);
		status = __geom_contains_point(&__geom1, &pt, dl);
		if (status == PT_ERROR)
			return false;
		if (status == PT_OUTSIDE)
			return __geom_dist2d_ptarray_ptarray(&__geom1, &__geom2, dl);
	}

	/* 3. check if first point of poly2 is in a hole of poly1.
	 * If so check outer ring of poly2 against that hole of poly1
	 */
	__loadPoint2d(&pt, __geom2.rawdata, 0);
	pos = __geom1.rawdata + __geom1.rawsize;
	for (int i = 1; i < geom1->nitems; i++)
	{
		pos = __load_sub_geometry(&__gtemp, geom1, pos, i);
		status = __geom_contains_point(&__gtemp, &pt, dl);
		if (status == PT_ERROR)
			return false;
		if (status != PT_OUTSIDE)
			return __geom_dist2d_ptarray_ptarray(&__gtemp, &__geom2, dl);
	}

	/* 4. check if first point of poly1 is in a hole of poly2.
	 * If so check outer ring of poly1 against that hole of poly2
	 */
	 __loadPoint2d(&pt, __geom1.rawdata, 0);
	 pos = __geom2.rawdata + __geom2.rawsize;
	 for (int i = 1; i < geom2->nitems; i++)
	 {
		 pos = __load_sub_geometry(&__gtemp, geom2, pos, i);
		 status = __geom_contains_point(&__gtemp, &pt, dl);
		 if (status == PT_ERROR)
			 return false;
		 if (status != PT_OUTSIDE)
			 return __geom_dist2d_ptarray_ptarray(&__geom1, &__gtemp, dl);
	 }

	 /* 5. If we have come all the way here we know that the first
	  * point of one of them is inside the other ones outer ring and
	  * not in holes so we check wich one is inside.
	  */
	 __loadPoint2d(&pt, __geom1.rawdata, 0);
	 status = __geom_contains_point(&__geom2, &pt, dl);
	 if (status == PT_ERROR)
		 return false;
	 if (status != PT_OUTSIDE)
	 {
		 dl->distance = 0.0;
		 dl->p1 = pt;
		 dl->p2 = pt;
		 return true;
	 }

	 __loadPoint2d(&pt, __geom2.rawdata, 0);
	 status = __geom_contains_point(&__geom1, &pt, dl);
	 if (status == PT_ERROR)
		 return false;
	 if (status != PT_OUTSIDE)
	 {
		 dl->distance = 0.0;
		 dl->p1 = pt;
		 dl->p2 = pt;
		 return true;
	 }
	 return false;
}

STATIC_INLINE(cl_bool)
geom_dist2d_poly_poly(const pg_geometry_t *geom1,
					  const pg_geometry_t *geom2,
					  DISTPTS *dl)
{
	/* see lw_dist2d_poly_poly */
	assert(geom1->type == GEOM_POLYGONTYPE &&
		   geom2->type == GEOM_POLYGONTYPE);
	return __geom_dist2d_xpoly_xpoly(geom1, geom2, dl);
}

STATIC_INLINE(cl_bool)
geom_dist2d_poly_curvepoly(const pg_geometry_t *geom1,
						   const pg_geometry_t *geom2,
						   DISTPTS *dl)
{
	/* see lw_dist2d_poly_curvepoly */
	assert(geom1->type == GEOM_POLYGONTYPE &&
		   geom2->type == GEOM_CURVEPOLYTYPE);
	return __geom_dist2d_xpoly_xpoly(geom1, geom2, dl);
}

STATIC_INLINE(cl_bool)
geom_dist2d_curvepoly_curvepoly(const pg_geometry_t *geom1,
								const pg_geometry_t *geom2,
								DISTPTS *dl)
{
	/* see lw_dist2d_curvepoly_curvepoly */
	assert(geom1->type == GEOM_CURVEPOLYTYPE &&
		   geom2->type == GEOM_CURVEPOLYTYPE);
	return __geom_dist2d_xpoly_xpoly(geom1, geom2, dl);
}

STATIC_FUNCTION(cl_bool)
geom_dist2d_recursive(const pg_geometry_t *geom1,
					  const pg_geometry_t *geom2,
					  DISTPTS *dl)
{
	/* see lw_dist2d_recursive() */
	pg_geometry_t	__geom;
	const char	   *rawdata;

	assert(!geom1->isnull && !geom2->isnull);
	if (geometry_type_is_collection(geom1->type))
	{
		rawdata = geom1->rawdata;
		for (int i=0; i < geom1->nitems; i++)
		{
			memset(&__geom, 0, sizeof(pg_geometry_t));
			__geom.type = __Fetch((cl_int *)rawdata);
			rawdata += sizeof(cl_int);
			__geom.flags = geom1->flags;
			__geom.srid  = geom1->srid;
			__geom.nitems = __Fetch((cl_uint *)rawdata);
			rawdata += sizeof(cl_uint);
			__geom.rawdata = rawdata;
			if (!setup_geometry_rawsize(&__geom) ||
				__geom.rawdata+__geom.rawsize > geom1->rawdata+geom1->rawsize)
			{
				STROM_EREPORT(dl->kcxt, ERRCODE_DATA_CORRUPTED,
							  "geometry data curruption");
				return false;
			}
			if (!geom_dist2d_recursive(&__geom, geom2, dl))
				return false;
			rawdata += __geom.rawsize;
		}
	}
	else if (geometry_type_is_collection(geom2->type))
	{
		rawdata = geom2->rawdata;
		for (int i=0; i < geom2->nitems; i++)
		{
			memset(&__geom, 0, sizeof(pg_geometry_t));
            __geom.type = __Fetch((cl_int *)rawdata);
			rawdata += sizeof(cl_int);
			__geom.flags = geom2->flags;
            __geom.srid  = geom2->srid;
            __geom.nitems = __Fetch((cl_uint *)rawdata);
			rawdata += sizeof(cl_uint);
			__geom.rawdata = rawdata;
			if (!setup_geometry_rawsize(&__geom) ||
				__geom.rawdata+__geom.rawsize > geom2->rawdata+geom2->rawsize)
			{
				STROM_EREPORT(dl->kcxt, ERRCODE_DATA_CORRUPTED,
							  "geometry data curruption");
				return false;
			}
			if (!geom_dist2d_recursive(geom1, &__geom, dl))
				return false;
			rawdata += __geom.rawsize;
		}
	}
	else if (geom1->nitems > 0 && geom2->nitems)
	{
		/*
		 * see lw_dist2d_distribute_bruteforce()
		 *
		 * NOTE that we don't use the logic of lw_dist2d_distribute_fast()
		 * here, even if both geometries are line, polygon, or triangle,
		 * because it internally allocates variable length buffer to sort
		 * the points. It is not easy to implement on GPU device.
		 */
		switch (geom1->type)
		{
			case GEOM_POINTTYPE:
				dl->twisted = 1;
				switch (geom2->type)
				{
					case GEOM_POINTTYPE:
						return geom_dist2d_point_point(geom1,geom2,dl);
					case GEOM_LINETYPE:
						return geom_dist2d_point_line(geom1,geom2,dl);
					case GEOM_TRIANGLETYPE:
						return geom_dist2d_point_tri(geom1,geom2,dl);
					case GEOM_POLYGONTYPE:
						return geom_dist2d_point_poly(geom1,geom2,dl);
					case GEOM_CIRCSTRINGTYPE:
						return geom_dist2d_point_circstring(geom1,geom2,dl);
					case GEOM_CURVEPOLYTYPE:
						return geom_dist2d_point_curvepoly(geom1,geom2,dl);
					default:
						STROM_ELOG(dl->kcxt, "unknown geometry data type");
						return false;
				}
			case GEOM_LINETYPE:
				dl->twisted = 1;
				switch (geom2->type)
				{
					case GEOM_POINTTYPE:
						dl->twisted = -1;
						return geom_dist2d_point_line(geom2,geom1,dl);
					case GEOM_LINETYPE:
						return geom_dist2d_line_line(geom1,geom2,dl);
					case GEOM_TRIANGLETYPE:
						return geom_dist2d_line_tri(geom1,geom2,dl);
					case GEOM_POLYGONTYPE:
						return geom_dist2d_line_poly(geom1,geom2,dl);
					case GEOM_CIRCSTRINGTYPE:
						return geom_dist2d_line_circstring(geom1,geom2,dl);
					case GEOM_CURVEPOLYTYPE:
						return geom_dist2d_line_curvepoly(geom1,geom2,dl);
					default:
						STROM_ELOG(dl->kcxt, "unknown geometry data type");
						return false;
				}
			case GEOM_TRIANGLETYPE:
				dl->twisted = 1;
				switch (geom2->type)
				{
					case GEOM_POINTTYPE:
						dl->twisted = -1;
						return geom_dist2d_point_tri(geom2,geom1,dl);
					case GEOM_LINETYPE:
						dl->twisted = -1;
						return geom_dist2d_line_tri(geom2,geom1,dl);
					case GEOM_TRIANGLETYPE:
						return geom_dist2d_tri_tri(geom1,geom2,dl);
					case GEOM_POLYGONTYPE:
						return geom_dist2d_tri_poly(geom1,geom2,dl);
					case GEOM_CIRCSTRINGTYPE:
						return geom_dist2d_tri_circstring(geom1,geom2,dl);
					case GEOM_CURVEPOLYTYPE:
						return geom_dist2d_tri_curvepoly(geom1,geom2,dl);
					default:
						STROM_ELOG(dl->kcxt, "unknown geometry data type");
						return false;
				}
			case GEOM_CIRCSTRINGTYPE:
				dl->twisted = 1;
				switch (geom2->type)
				{
					case GEOM_POINTTYPE:
						dl->twisted = -1;
						return geom_dist2d_point_circstring(geom2,geom1,dl);
					case GEOM_LINETYPE:
						dl->twisted = -1;
						return geom_dist2d_line_circstring(geom2,geom1,dl);
					case GEOM_TRIANGLETYPE:
						dl->twisted = -1;
						return geom_dist2d_tri_circstring(geom2,geom1,dl);
					case GEOM_POLYGONTYPE:
						return geom_dist2d_circstring_poly(geom1,geom2,dl);
					case GEOM_CIRCSTRINGTYPE:
						return geom_dist2d_circstring_circstring(geom1,
																 geom2,dl);
					case GEOM_CURVEPOLYTYPE:
						return geom_dist2d_circstring_curvepoly(geom1,
																geom2,dl);
					default:
						STROM_ELOG(dl->kcxt, "unknown geometry data type");
						return false;
				}
			case GEOM_POLYGONTYPE:
				dl->twisted = -1;
				switch (geom2->type)
				{
					case GEOM_POINTTYPE:
						return geom_dist2d_point_poly(geom2,geom1,dl);
					case GEOM_LINETYPE:
						return geom_dist2d_line_poly(geom2,geom1,dl);
					case GEOM_TRIANGLETYPE:
						return geom_dist2d_tri_poly(geom2,geom1,dl);
					case GEOM_POLYGONTYPE:
						dl->twisted = 1;
						return geom_dist2d_poly_poly(geom1,geom2,dl);
					case GEOM_CIRCSTRINGTYPE:
						return geom_dist2d_circstring_poly(geom2,geom1,dl);
					case GEOM_CURVEPOLYTYPE:
						dl->twisted = 1;
						return geom_dist2d_poly_curvepoly(geom1,geom2,dl);
					default:
						STROM_ELOG(dl->kcxt, "unknown geometry data type");
						return false;
				}
			case GEOM_CURVEPOLYTYPE:
				dl->twisted = -1;
				switch (geom2->type)
				{
					case GEOM_POINTTYPE:
						return geom_dist2d_point_curvepoly(geom2,geom1,dl);
					case GEOM_LINETYPE:
						return geom_dist2d_line_curvepoly(geom2,geom1,dl);
					case GEOM_TRIANGLETYPE:
						return geom_dist2d_tri_curvepoly(geom2,geom1,dl);
					case GEOM_POLYGONTYPE:
						return geom_dist2d_poly_curvepoly(geom2,geom1,dl);
					case GEOM_CIRCSTRINGTYPE:
						return geom_dist2d_circstring_curvepoly(geom2,
																geom1,dl);
					case GEOM_CURVEPOLYTYPE:
						dl->twisted = 1;
						return geom_dist2d_curvepoly_curvepoly(geom1,
															   geom2,dl);
					default:
						STROM_ELOG(dl->kcxt, "unknown geometry data type");
						return false;
				}
			default:
				STROM_ELOG(dl->kcxt, "unknown geometry data type");
				return false;
		}
	}
	return true;
}

DEVICE_FUNCTION(pg_float8_t)
pgfn_st_distance(kern_context *kcxt,
				 const pg_geometry_t &geom1,
				 const pg_geometry_t &geom2)
{
	pg_float8_t	result;
	DISTPTS		dl;

	result.isnull = geom1.isnull | geom2.isnull;
	if (!result.isnull)
	{
		if (geom1.srid != geom2.srid)
		{
			STROM_EREPORT(kcxt, ERRCODE_INVALID_PARAMETER_VALUE,
						  "Operation on mixed SRID geometries");
			result.isnull = true;
		}
		else
		{
			memset(&dl, 0, sizeof(DISTPTS));
			dl.kcxt = kcxt;
			dl.distance = DBL_MAX;
			if (!geom_dist2d_recursive(&geom1, &geom2, &dl))
				result.isnull = true;
			else
				result.value = dl.distance;
		}
	}
	return result;
}
